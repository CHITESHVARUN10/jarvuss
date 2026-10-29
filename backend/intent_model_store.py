"""Verified intent releases outside the signed app; no network or credentials.

The macOS downloader atomically selects an immutable version via current.json.
last-good.json is written only after the runtime successfully loads and warms
that release, allowing a cold-start fallback if a newer release is unusable.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from tempfile import NamedTemporaryFile

COMMIT = re.compile(r"[0-9a-f]{40}")
DIRECTORY = re.compile(r"[0-9a-f]{40}-[0-9a-f]{32}")
FILES = frozenset({"encoder_model_quantized.onnx", "decoder_model_merged_quantized.onnx", "config.json",
                   "generation_config.json", "added_tokens.json", "spiece.model", "special_tokens_map.json",
                   "tokenizer.json", "tokenizer_config.json", "model_meta.json", "LICENSE", "NOTICE"})
REQUIRED = frozenset({"encoder_model_quantized.onnx", "decoder_model_merged_quantized.onnx", "config.json",
                      "added_tokens.json", "spiece.model", "model_meta.json"})


def fingerprint(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""): digest.update(chunk)
    return digest.hexdigest()


def receipt(root: Path, name="current.json") -> dict | None:
    try:
        path = root / name
        if path.stat().st_size > 8192: return None
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or not COMMIT.fullmatch(value.get("commit", "")): return None
        directory = value.get("directory", "")
        if not DIRECTORY.fullmatch(directory) or not directory.startswith(value["commit"] + "-"): return None
        if not re.fullmatch(r"[0-9a-f]{64}", value.get("manifest_sha256", "")): return None
        if not isinstance(value.get("version"), str) or not isinstance(value.get("generation"), str): return None
        return value
    except (OSError, ValueError, TypeError): return None


def verify(root: Path, selected: dict) -> Path:
    folder = root / "versions" / selected["directory"]
    if folder.is_symlink() or folder.resolve().parent != (root / "versions").resolve():
        raise ValueError("invalid managed model location")
    manifest_file = folder / "model-release.json"
    if manifest_file.is_symlink() or manifest_file.stat().st_size > 64000:
        raise ValueError("invalid managed model manifest")
    if fingerprint(manifest_file) != selected["manifest_sha256"]: raise ValueError("model manifest checksum mismatch")
    manifest = json.loads(manifest_file.read_text())
    if (manifest.get("format_version") != 1 or manifest.get("runtime") != "jarvis-t5-onnx-v1"
            or manifest.get("version") != selected["version"]
            or type(manifest.get("intent_schema_version")) is not int or not 1 <= manifest["intent_schema_version"] <= 4
            or manifest.get("max_source_len") != 128 or manifest.get("max_target_len") != 448):
        raise ValueError("incompatible managed model")
    files = manifest.get("files")
    if not isinstance(files, list) or not 6 <= len(files) <= 12: raise ValueError("invalid model file count")
    names = [item.get("name") for item in files if isinstance(item, dict)]
    if len(names) != len(files) or len(set(names)) != len(names) or not REQUIRED <= set(names) <= FILES:
        raise ValueError("invalid model file list")
    if manifest.get("license") == "apache-2.0" and not {"LICENSE", "NOTICE"} <= set(names):
        raise ValueError("model license notices missing")
    total = 0
    for item in files:
        path = folder / item["name"]
        size, digest = item.get("size_bytes"), item.get("sha256")
        if type(size) is not int or not 0 < size <= 256000000: raise ValueError("invalid model size")
        total += size
        if total > 350000000: raise ValueError("model exceeds size limit")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest): raise ValueError("invalid model checksum")
        if path.is_symlink() or not path.is_file() or path.stat().st_size != size or fingerprint(path) != digest:
            raise ValueError("model file verification failed")
    return folder


def remember_good(root: Path, selected: dict) -> None:
    root.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(mode="w", dir=root, prefix=".last-good-", delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(selected, handle)
    try: temporary.replace(root / "last-good.json")
    finally: temporary.unlink(missing_ok=True)
