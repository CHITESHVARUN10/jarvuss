"""Model-store and hot-reload tests; no actual ONNX inference or network."""
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import intent_model_store as store
import intent_router_model as router


class ModelUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="jarvis-intent-backend-", dir="/private/tmp")
        self.data = Path(self.tmp.name)
        self.root = self.data / "models" / "intent"
        self.root.mkdir(parents=True)
        self.bundled = self.data / "bundled"; self.bundled.mkdir()
        self.env = patch.dict(os.environ, {"JARVIS_DATA_DIR": str(self.data)}, clear=False); self.env.start()
        self.override = os.environ.pop("JARVIS_INTENT_MODEL_DIR", None)
        self.reset = patch.multiple(router, _engine=None, _load_error=None, _selection_key=None, _active_release={"source": "not loaded"}, _update_error=None, MODEL_DIR=self.bundled)
        self.reset.start()
    def tearDown(self):
        self.reset.stop()
        if self.override is not None: os.environ["JARVIS_INTENT_MODEL_DIR"] = self.override
        self.env.stop(); self.tmp.cleanup()

    def install(self, char="a", version="1.0.0"):
        commit = char * 40
        directory = commit + "-" + char * 32
        folder = self.root / "versions" / directory; folder.mkdir(parents=True, exist_ok=True)
        entries = []
        for name in sorted(store.REQUIRED):
            data = b"example data"; (folder / name).write_bytes(data)
            entries.append({"name": name, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {"format_version": 1, "runtime": "jarvis-t5-onnx-v1", "version": version, "intent_schema_version": 3,
                    "max_source_len": 128, "max_target_len": 448, "files": entries}
        encoded = json.dumps(manifest).encode(); (folder / "model-release.json").write_bytes(encoded)
        selected = {"commit": commit, "directory": directory, "version": version,
                    "manifest_sha256": hashlib.sha256(encoded).hexdigest(), "generation": char}
        (self.root / "current.json").write_text(json.dumps(selected))
        return selected, folder

    def test_receipt_verification_and_traversal_rejection(self):
        selected, folder = self.install()
        self.assertEqual(store.receipt(self.root), selected)
        self.assertEqual(store.verify(self.root, selected), folder)
        selected["directory"] = "../../outside"
        (self.root / "current.json").write_text(json.dumps(selected))
        self.assertIsNone(store.receipt(self.root))

    def test_checksum_failure_symlink_and_incompatible_runtime_are_rejected(self):
        selected, folder = self.install()
        (folder / "config.json").write_bytes(b"altered data")
        with self.assertRaises(ValueError): store.verify(self.root, selected)
        selected, folder = self.install()
        target = folder / "spiece.model"; target.unlink(); target.symlink_to(folder / "config.json")
        with self.assertRaises(ValueError): store.verify(self.root, selected)
        selected, folder = self.install("b")
        manifest = json.loads((folder / "model-release.json").read_text()); manifest["runtime"] = "unrecognized-runtime"
        encoded = json.dumps(manifest).encode(); (folder / "model-release.json").write_bytes(encoded)
        selected["manifest_sha256"] = hashlib.sha256(encoded).hexdigest()
        with self.assertRaises(ValueError): store.verify(self.root, selected)

    def test_licensed_release_requires_verified_notices(self):
        selected, folder = self.install()
        manifest = json.loads((folder / "model-release.json").read_text())
        manifest["license"] = "apache-2.0"
        def write_manifest():
            encoded = json.dumps(manifest).encode()
            (folder / "model-release.json").write_bytes(encoded)
            selected["manifest_sha256"] = hashlib.sha256(encoded).hexdigest()
        write_manifest()
        with self.assertRaisesRegex(ValueError, "license notices missing"): store.verify(self.root, selected)
        for name in ("LICENSE", "NOTICE"):
            data = b"Sample Apache license notice"
            (folder / name).write_bytes(data)
            manifest["files"].append({"name": name, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        write_manifest()
        self.assertEqual(store.verify(self.root, selected), folder)
        (folder / "NOTICE").write_bytes(b"tampered Apache notice text")
        with self.assertRaises(ValueError): store.verify(self.root, selected)

    def test_new_install_is_loaded_after_prior_missing_model_error(self):
        self.bundled.rmdir()
        with patch.object(router, "_OnnxIntentEngine", FakeEngine) as engine:
            router._load()
            self.assertIsNone(router._engine)
            selected, _ = self.install()
            router._load()
            self.assertIsNotNone(router._engine)
            self.assertEqual(router._active_release["version"], "1.0.0")
            self.assertEqual(store.receipt(self.root, "last-good.json"), selected)

    def test_update_activates_without_restarting_helper_and_unchanged_request_is_cached(self):
        self.install()
        with patch.object(router, "_OnnxIntentEngine", FakeEngine):
            router._load(); original = router._engine
            router._load(); self.assertIs(router._engine, original)
            self.install("b", "1.1.0")
            router._load(); self.assertIsNot(router._engine, original)
            self.assertEqual(router._active_release["version"], "1.1.0")

    def test_bad_update_keeps_in_memory_working_model(self):
        self.install()
        with patch.object(router, "_OnnxIntentEngine", FakeEngine): router._load()
        original = router._engine
        self.install("b", "1.1.0")
        with patch.object(router, "_OnnxIntentEngine", side_effect=ValueError("unsupported ONNX")):
            router._load()
        self.assertIs(router._engine, original)
        self.assertIsNotNone(router._update_error)
        self.assertEqual(router._active_release["version"], "1.0.0")

    def test_cold_start_recovers_previous_verified_release(self):
        good, good_folder = self.install(); store.remember_good(self.root, good)
        _, bad_folder = self.install("b", "1.1.0")
        (bad_folder / "config.json").write_bytes(b"corrupt")
        with patch.object(router, "_OnnxIntentEngine", FakeEngine): router._load()
        self.assertEqual(router._engine.folder, good_folder)
        self.assertEqual(router._active_release["source"], "previous downloaded")

    def test_status_does_not_initialize_onnx(self):
        self.install()
        with patch.object(router, "_OnnxIntentEngine", side_effect=AssertionError("must remain lazy")):
            status = router.intent_model_status()
        self.assertFalse(status["loaded"])

    def test_explicit_model_override_remains_supported(self):
        self.install()
        with patch.dict(os.environ, {"JARVIS_INTENT_MODEL_DIR": str(self.bundled)}), patch.object(router, "_OnnxIntentEngine", FakeEngine): router._load()
        self.assertEqual(router._engine.folder, self.bundled)
        self.assertEqual(router._active_release["source"], "configured")


class FakeEngine:
    def __init__(self, folder): self.folder = folder
    def generate(self, text):
        if text != "pause": raise ValueError("warmup must use raw text without a doubled parse prefix")
        return '[{"name":"media.pause","args":{}}]', .99

if __name__ == "__main__": unittest.main()
