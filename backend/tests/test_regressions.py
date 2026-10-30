"""Run: python -m unittest discover -s backend/tests -v

Uses real FastAPI/NumPy and replaces the voice model only. No model downloads,
Keychain writes, live Spotify calls, or changes to an enrolled voice profile.
"""
from __future__ import annotations

import asyncio
import importlib.util
import io
import json
import os
import sys
import tempfile
import subprocess
import threading
import types
import unittest
import uuid
import ctypes
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

# Resemblyzer pulls in torch; these tests exercise scheduling/storage, not
# model quality. The numerical and HTTP implementations remain real.
fake_voice = types.ModuleType("resemblyzer")
fake_voice.VoiceEncoder = Mock()
fake_voice.preprocess_wav = Mock()
sys.modules.setdefault("resemblyzer", fake_voice)

import numpy as np
import httpx
from fastapi import UploadFile
import intent_router_model as intent
import voice_auth_service as service
from runtime_config import RuntimeConfig, SECRET_KEYS, read_env, Keychain

spec = importlib.util.spec_from_file_location("post_train_review_tests", ROOT / "training/post_train.py")
training = importlib.util.module_from_spec(spec)
spec.loader.exec_module(training)


class LazyVoiceImportTests(unittest.TestCase):
    def test_health_import_does_not_import_voice_dependencies(self):
        script = """
import builtins
original_import = builtins.__import__
def guarded_import(name, *args, **kwargs):
    if name.split('.')[0] in {'torch', 'resemblyzer'}:
        raise AssertionError('Voice dependency imported before a voice request: ' + name)
    return original_import(name, *args, **kwargs)
builtins.__import__ = guarded_import
import voice_auth_service as service
assert service.encoder is None
assert service._voice_stack is None
assert service.health()['status'] == 'ok'
"""
        result = subprocess.run([sys.executable, "-B", "-c", script], cwd=ROOT / "backend",
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)


class MemoryKeychain:
    def __init__(self):
        self.values = {}
    def get(self, key):
        return self.values.get(key)
    def set(self, key, value):
        self.values[key] = value


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("JARVIS_RUN_KEYCHAIN_TESTS") == "1",
                     "Native Keychain integration is opt-in; default tests use an in-memory store")
class NativeKeychainTests(unittest.TestCase):
    def test_native_roundtrip_and_update_with_temporary_entry(self):
        keychain = Keychain()
        account = "jarvis-test-" + uuid.uuid4().hex
        try:
            self.assertIsNone(keychain.get(account))
            value = "test-only 'quotes' $() spaces\n café"
            keychain.set(account, value)
            self.assertEqual(keychain.get(account), value)
            keychain.set(account, "updated test value")
            self.assertEqual(keychain.get(account), "updated test value")
        finally:
            # Delete only this test's unique account, including after failure.
            delete = keychain.sec.SecItemDelete
            delete.argtypes, delete.restype = [ctypes.c_void_p], ctypes.c_int32
            with ExitStack() as stack:
                query, _ = keychain._query(stack, account)
                status = delete(query)
                self.assertIn(status, (0, -25300))


class ConfigurationTests(unittest.TestCase):
    def test_secrets_never_enter_settings_and_saved_edits_override_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            keychain = MemoryKeychain()
            store = RuntimeConfig(Path(directory), keychain)
            password = "spaces ' quotes $() ; \n and unicode café"
            store.save({"PGHOST": "new-host", "PGPASSWORD": password,
                        "SPOTIFY_REFRESH_TOKEN": "refresh-secret"})
            saved = json.loads(store.path.read_text())
            self.assertFalse(SECRET_KEYS.intersection(saved))
            reloaded = RuntimeConfig(Path(directory), keychain)
            values = reloaded.load({"PGHOST": "old-host", "PGPASSWORD": "old-password"})
            self.assertEqual(values["PGHOST"], "new-host")
            self.assertEqual(values["PGPASSWORD"], password)
            self.assertEqual(values["SPOTIFY_REFRESH_TOKEN"], "refresh-secret")

    def test_running_backend_reads_secrets_changed_by_swift_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            keychain = MemoryKeychain()
            store = RuntimeConfig(Path(directory), keychain)
            store.save({"PGPASSWORD": "old"})
            self.assertEqual(store.load({})["PGPASSWORD"], "old")
            # Swift saves Keychain and atomically replaces the shared settings
            # file. A second store reproduces that cross-process edit.
            RuntimeConfig(Path(directory), keychain).save({"PGPASSWORD": "updated-by-setup"})
            self.assertEqual(store.load({})["PGPASSWORD"], "updated-by-setup")

    def test_repeated_loads_cache_only_the_requested_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            keychain = MemoryKeychain()
            keychain.get = Mock(wraps=keychain.get)
            store = RuntimeConfig(Path(directory), keychain)
            for _ in range(8):
                store.load({}, secret_keys={"SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN"})
            self.assertEqual(keychain.get.call_count, 3)
            self.assertNotIn(unittest.mock.call("PGPASSWORD"), keychain.get.call_args_list)

    def test_token_updates_are_cached_and_never_written_to_json(self):
        with tempfile.TemporaryDirectory() as directory:
            keychain = MemoryKeychain()
            keychain.get = Mock(wraps=keychain.get)
            store = RuntimeConfig(Path(directory), keychain)
            store.load({})
            before = keychain.get.call_count
            store.save({"SPOTIFY_ACCESS_TOKEN": "fresh", "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT": "123"})
            self.assertEqual(store.load({})["SPOTIFY_ACCESS_TOKEN"], "fresh")
            self.assertEqual(keychain.get.call_count, before)
            self.assertEqual(json.loads(store.path.read_text()), {"SPOTIFY_ACCESS_TOKEN_EXPIRES_AT": "123"})

    def test_env_is_read_as_literal_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("PGPASSWORD=$(touch /this-must-never-run)\n")
            self.assertEqual(read_env(path)["PGPASSWORD"], "$(touch /this-must-never-run)")

    def test_quoted_export_values_preserve_spaces_without_shell_evaluation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("export PGPASSWORD='  literal $(command)  '\nTOKEN=\"quoted=value\"\n")
            self.assertEqual(read_env(path), {"PGPASSWORD": "  literal $(command)  ", "TOKEN": "quoted=value"})

    def test_concurrent_saves_preserve_independent_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            store = RuntimeConfig(Path(directory), MemoryKeychain())
            threads = [threading.Thread(target=store.save, args=({f"key{i}": str(i)},)) for i in range(12)]
            for thread in threads: thread.start()
            for thread in threads: thread.join()
            self.assertEqual(len(json.loads(store.path.read_text())), 12)

    def test_migration_preserves_saved_edits_and_ignores_unrelated_env_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            keychain = MemoryKeychain()
            store = RuntimeConfig(Path(directory), keychain)
            store.save({"PGHOST": "saved-host", "PGPASSWORD": "saved-password"})
            store.import_defaults({"PGHOST": "old-host", "PGPASSWORD": "old-password",
                                   "OTHER_SERVICE_API_KEY": "must-not-be-copied"})
            self.assertEqual(json.loads(store.path.read_text()), {"PGHOST": "saved-host"})
            self.assertEqual(keychain.get("PGPASSWORD"), "saved-password")


class Tokenizer:
    def encode(self, text):
        self.seen = text
        return [3] * len(text.split())


class IntentEncodingTests(unittest.TestCase):
    def engine(self):
        engine = object.__new__(intent._OnnxIntentEngine)
        engine.sp = Tokenizer()
        engine.brace_to_id = {}
        return engine

    def test_long_character_input_is_not_cut_before_tokenization(self):
        engine = self.engine()
        text = "parse: " + "please " * 15 + "open spotify"
        ids = engine.encode(text)
        self.assertGreater(len(text), 96)
        self.assertEqual(engine.sp.seen, text)
        self.assertEqual(ids[-1], intent.EOS_ID)

    def test_eos_slot_is_reserved_and_overflow_is_explicit(self):
        engine = self.engine()
        self.assertEqual(len(engine.encode("word " * (intent.MAX_SOURCE_LEN - 1))), intent.MAX_SOURCE_LEN)
        with self.assertRaises(intent.InputTooLong): engine.encode("word " * intent.MAX_SOURCE_LEN)

    def test_overflow_endpoint_returns_miss_instead_of_partial_plan(self):
        engine = Mock()
        engine.generate.side_effect = intent.InputTooLong()
        with patch.object(intent, "_load"), patch.object(intent, "_engine", engine):
            result = intent.parse_intent(intent.ParseIntentRequest(text="long input"))
        self.assertFalse(result["parse_ok"])
        self.assertIsNone(result["actions"])
        self.assertEqual(result["reason"], "input_too_long")


class TrainingLabelTests(unittest.TestCase):
    action = {"name": "app.open", "args": {"name": "Spotify"}}

    def harvest(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows))
            return training.harvest(str(path), training.load_schema())[0]

    def events(self):
        return [
            {"event": "model_hit", "request_id": "one", "text": "open spotify", "actions": [self.action]},
            {"event": "plan", "request_id": "one", "text": "open spotify", "actions": ["Open 'Spotify'"]},
            {"event": "execute_step", "request_id": "one", "success": True},
            {"event": "execute_command", "request_id": "one", "success": True, "outcome": "success"},
        ]

    def test_explicitly_successful_complete_run_is_harvested(self):
        pairs = self.harvest(self.events())
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0]["source"], "model_hit")

    def test_native_descriptions_round_trip_and_only_authored_corrections_are_rewarded(self):
        row = json.loads((ROOT / "dataset/train-066-native-search.jsonl").read_text().splitlines()[0])
        action = row["intents"][0]
        description = "File search: " + json.dumps(row["resolved_args"])
        self.assertEqual(training.description_to_intent(description), action)
        self.assertEqual(training.description_to_intent("File result: preview 2"),
                         {"name": "files.result", "args": {}})
        self.assertEqual(training.description_to_intent("Settings: bluetooth"),
                         {"name": "settings.open", "args": {}})
        self.assertTrue(training.is_consistent(row["text"], [action]))
        self.assertFalse(training.is_consistent("find the unrelated secret spreadsheet", [action]))
        events = [
            {"event": "plan", "request_id": "search", "text": row["text"], "actions": [description]},
            {"event": "execute_step", "request_id": "search", "success": True},
            {"event": "execute_command", "request_id": "search", "success": True, "outcome": "success"},
        ]
        self.assertEqual(len(self.harvest(events)), 1)
        events[0]["text"] = "find the unrelated secret spreadsheet"
        self.assertEqual(self.harvest(events), [])

    def test_failed_model_hit_is_never_rewarded(self):
        rows = self.events()
        rows[-1]["success"] = False
        self.assertEqual(self.harvest(rows), [])

    def test_incomplete_or_cancelled_runs_are_never_rewarded(self):
        rows = self.events()
        self.assertEqual(self.harvest(rows[:-1]), [])
        rows[-1]["outcome"] = "cancelled"
        self.assertEqual(self.harvest(rows), [])

    def test_failed_step_overrides_legacy_command_success_flag(self):
        rows = self.events()
        rows[2]["success"] = False
        self.assertEqual(self.harvest(rows), [])

    def test_rejected_model_plan_cannot_override_successful_fallback(self):
        rows = self.events()
        rows[0]["actions"] = [{"name": "app.open", "args": {"name": "Chrome"}}]
        pairs = self.harvest(rows)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0]["source"], "executed_plan")
        self.assertIn("Spotify", pairs[0]["target_text"])


class VoiceSchedulingTests(unittest.IsolatedAsyncioTestCase):
    async def test_slow_voice_work_does_not_block_health(self):
        started, release = threading.Event(), threading.Event()
        def work():
            started.set()
            release.wait(timeout=5)
            return {"similarity": 1}
        task = asyncio.create_task(service._run_voice_job(work))
        try:
            await asyncio.wait_for(asyncio.to_thread(started.wait), timeout=1)
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=service.app), base_url="http://test") as client:
                with patch.object(service.app.state, "auth_token", "health-test-token"):
                    response = await asyncio.wait_for(client.get("/health", headers={"X-Jarvis-Token": "health-test-token"}), timeout=0.5)
            self.assertEqual(response.status_code, 200)
        finally:
            release.set()
            await task

    async def test_worker_queue_is_bounded_and_cancellation_keeps_slot_until_work_ends(self):
        started, release = threading.Event(), threading.Event()
        def work():
            started.set()
            release.wait(timeout=5)
        first = asyncio.create_task(service._run_voice_job(work))
        await asyncio.wait_for(asyncio.to_thread(started.wait), timeout=1)
        second = asyncio.create_task(service._run_voice_job(lambda: None))
        await asyncio.sleep(0)
        try:
            with self.assertRaises(service.HTTPException) as error:
                await service._run_voice_job(lambda: None)
            self.assertEqual(error.exception.status_code, 503)
            first.cancel()
            with self.assertRaises(asyncio.CancelledError): await first
            with self.assertRaises(service.HTTPException): await service._run_voice_job(lambda: None)
        finally:
            release.set()
            await second

    async def test_upload_is_bounded_before_embedding(self):
        upload = UploadFile(filename="large.wav", file=io.BytesIO(b"a" * (10 * 1024 * 1024 + 1)))
        with self.assertRaises(service.HTTPException) as error:
            await service._read_voice_upload(upload)
        self.assertEqual(error.exception.status_code, 413)


class VoiceStorageTests(unittest.TestCase):
    def test_enrollment_and_reset_update_runtime_profile_without_touching_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "legacy"
            legacy.mkdir()
            np.save(legacy / "embeddings.npy", np.ones((1, 256), dtype=np.float32))
            original = (legacy / "embeddings.npy").read_bytes()
            with patch.object(service, "BASE_DIR", legacy), patch.object(service, "EMBEDDINGS_FILE", root / "runtime/embeddings.npy"), \
                 patch.object(service, "_embedding_from_audio_bytes", return_value=np.ones(256, dtype=np.float32)):
                self.assertEqual(service._enroll_audio(b"audio", ".wav")["enrolled_count"], 2)
                service._reset_profile()
                self.assertEqual(service._load_embeddings().shape, (0, 256))
            self.assertEqual((legacy / "embeddings.npy").read_bytes(), original)


class SpotifyEfficiencyTests(unittest.TestCase):
    def setUp(self): service._invalidate_spotify_device()

    def test_successful_transfer_uses_target_without_waiting_for_stale_active_flag(self):
        with patch.object(service, "_spotify_devices", return_value=[{"id": "desktop", "is_active": False, "type": "Computer"}]) as devices, \
             patch.object(service, "_spotify_api_request", return_value=(204, None, "")) as request, \
             patch.object(service.time, "sleep") as sleep:
            result = service._spotify_transport_action("token", "PUT", "/v1/me/player/play", "play", {})
            self.assertTrue(result["action_confirmed"])
            self.assertEqual(devices.call_count, 1)
            sleep.assert_not_called()
            self.assertEqual(request.call_args_list[0].kwargs["body"], {"device_ids": ["desktop"], "play": False})
            self.assertEqual(request.call_args_list[1].kwargs["query"], {"device_id": "desktop"})

    def test_restricted_devices_are_skipped_and_desktop_is_preferred(self):
        devices = [{"id": "restricted", "is_active": True, "is_restricted": True},
                   {"id": "phone", "type": "Smartphone"}, {"id": "desktop", "type": "Computer"}]
        with patch.object(service, "_spotify_devices", return_value=devices), \
             patch.object(service, "_spotify_api_request", return_value=(204, None, "")) as request:
            self.assertEqual(service._ensure_spotify_active_device("token"), "desktop")
            self.assertEqual(request.call_args.kwargs["body"], {"device_ids": ["desktop"], "play": False})

    def test_transfer_failure_does_not_cache_device_or_report_success(self):
        with patch.object(service, "_spotify_devices", return_value=[{"id": "desktop", "is_active": False}]), \
             patch.object(service, "_spotify_api_request", return_value=(403, None, "Premium required")) as request:
            with self.assertRaises(service.HTTPException) as error:
                service._spotify_transport_action("token", "PUT", "/v1/me/player/play", "play", {})
            self.assertEqual(error.exception.status_code, 403)
            self.assertEqual(request.call_count, 1)
            self.assertLess(service._device_cache["expires_at"], service.time.monotonic())

    def test_pause_recovery_does_not_start_playback(self):
        with patch.object(service, "_spotify_devices", return_value=[{"id": "desktop", "is_active": False}]), \
             patch.object(service, "_spotify_api_request", return_value=(204, None, "")) as request:
            service._spotify_transport_action("token", "PUT", "/v1/me/player/pause", "pause")
            self.assertIs(request.call_args_list[0].kwargs["body"]["play"], False)
            self.assertEqual(request.call_args_list[1].args[1], "/v1/me/player/pause")

    def test_transport_uses_cache_and_does_not_read_playback_state(self):
        with patch.object(service, "_spotify_devices", return_value=[{"id": "device", "is_active": True}]) as devices, \
             patch.object(service, "_spotify_api_request", return_value=(204, {}, "")) as request, \
             patch.object(service, "_spotify_playback_state") as state:
            for _ in range(2):
                result = service._spotify_transport_action("token", "POST", "/v1/me/player/next", "next")
                self.assertTrue(result["action_confirmed"])
            self.assertEqual(devices.call_count, 1)
            self.assertEqual(request.call_count, 2)
            state.assert_not_called()

    def test_stale_device_is_invalidated_and_retried_once(self):
        replies = [(404, {}, "no active device"), (204, {}, "")]
        with patch.object(service, "_spotify_devices", return_value=[{"id": "device", "is_active": True}]) as devices, \
             patch.object(service, "_spotify_api_request", side_effect=replies) as request:
            result = service._spotify_transport_action("token", "POST", "/v1/me/player/next", "next")
            self.assertEqual(result["status"], "ok")
            self.assertEqual(devices.call_count, 2)
            self.assertEqual(request.call_count, 2)

    def test_permanent_restriction_is_not_retried(self):
        with patch.object(service, "_spotify_devices", return_value=[{"id": "device", "is_active": True}]), \
             patch.object(service, "_spotify_api_request", return_value=(403, {}, "premium required")) as request:
            with self.assertRaises(service.HTTPException):
                service._spotify_transport_action("token", "POST", "/v1/me/player/next", "next")
            self.assertEqual(request.call_count, 1)


class SpotifyPlaybackConfirmationTests(unittest.TestCase):
    def test_empty_whitespace_and_non_json_responses_preserve_http_status(self):
        for status, raw in [(204, b""), (204, b"  \n"), (200, b" \n"), (200, b"Accepted")]:
            response = Mock(status=status)
            response.read.return_value = raw
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            with self.subTest(status=status, raw=raw), patch.object(service, "urlopen", return_value=response):
                code, payload, body = service._spotify_api_request("PUT", "/v1/me/player/play", "test-token", body={})
                self.assertEqual(code, status)
                self.assertIsNone(payload)
                self.assertEqual(body, raw.decode())

    def test_transport_errors_are_still_failures(self):
        with patch.object(service, "urlopen", side_effect=OSError("offline")):
            self.assertEqual(service._spotify_api_request("PUT", "/v1/me/player/play", "test-token")[0], -1)

    def test_plain_play_waits_for_correct_device_without_resending_action(self):
        states = [{"is_playing": False}, {"is_playing": True, "device_id": "phone"},
                  {"is_playing": True, "device_id": "desktop", "volume_percent": 40}]
        with patch.object(service, "_spotify_transport_action", return_value={"device_id": "desktop"}) as transport, \
             patch.object(service, "_spotify_playback_state", side_effect=states) as state, patch.object(service.time, "sleep"):
            result = service._spotify_play("token", {}, "play")
            self.assertTrue(result["playback_confirmed"])
            self.assertEqual(state.call_count, 3)
            transport.assert_called_once()

    def test_liked_and_playlist_requests_must_match_requested_content(self):
        for body, wrong, right in [({"uris": ["spotify:track:liked"]}, {"track_uri": "spotify:track:other"}, {"track_uri": "spotify:track:liked"}),
                                   ({"context_uri": "spotify:playlist:gym"}, {"context_uri": "spotify:playlist:other"}, {"context_uri": "spotify:playlist:gym"})]:
            base = {"is_playing": True, "device_id": "desktop"}
            with patch.object(service, "_spotify_transport_action", return_value={"device_id": "desktop"}), \
                 patch.object(service, "_spotify_playback_state", side_effect=[{**base, **wrong}, {**base, **right}]) as state, \
                 patch.object(service.time, "sleep"):
                self.assertTrue(service._spotify_play("token", body, "play")["playback_confirmed"])
                self.assertEqual(state.call_count, 2)

    def test_accepted_but_paused_unknown_wrong_track_or_muted_never_reports_completed(self):
        for state in [{"is_playing": False}, {}, {"is_playing": True, "device_id": "desktop", "track_uri": "other"},
                      {"is_playing": True, "device_id": "desktop", "track_uri": "liked", "volume_percent": 0}]:
            with self.subTest(state=state), patch.object(service, "_spotify_transport_action", return_value={"device_id": "desktop"}) as transport, \
                 patch.object(service, "_spotify_playback_state", return_value=state), patch.object(service.time, "sleep"):
                with self.assertRaises(service.HTTPException) as error:
                    service._spotify_play("token", {"uris": ["liked"]}, "play-liked")
                self.assertEqual(error.exception.status_code, 409)
                transport.assert_called_once()

    def test_liked_endpoint_uses_confirmation_and_surfaces_failure(self):
        with patch.object(service, "_get_valid_spotify_access_token", return_value="token"), \
             patch.object(service, "_spotify_liked_track_uris", return_value=["liked"]), \
             patch.object(service, "_spotify_transport_action", return_value={"device_id": "desktop"}), \
             patch.object(service, "_spotify_playback_state", return_value={"is_playing": False}), patch.object(service.time, "sleep"):
            with self.assertRaises(service.HTTPException) as error: service.spotify_play_liked()
            self.assertEqual(error.exception.status_code, 409)


class SpotifyNativeTargetTests(unittest.TestCase):
    def test_native_metadata_never_writes_to_player(self):
        with patch.object(service, "_get_valid_spotify_access_token", return_value="token"), \
             patch.object(service, "_spotify_api_request", side_effect=[(200, {"items": [{"track": {"uri": "spotify:track:first"}}]}, ""), (200, {"id": "test-account"}, "")]) as api, \
             patch.object(service, "_spotify_search_track_uri", return_value="spotify:track:one"), \
             patch.object(service, "_spotify_find_playlist_uri", return_value=("Gym", "spotify:playlist:gym")), \
             patch.object(service, "_spotify_liked_track_uris", return_value=["spotify:track:liked"]), \
             patch.object(service, "_spotify_transport_action") as transport:
            self.assertEqual(service.spotify_native_target("song", "Song"), {"uri": "spotify:track:one", "track_uri": "spotify:track:one"})
            self.assertEqual(service.spotify_native_target("playlist", "Gym"), {"uri": "spotify:playlist:gym", "track_uri": "spotify:track:first"})
            self.assertEqual(service.spotify_native_target("liked"), {"uri": "spotify:user:test-account:collection", "track_uri": "spotify:track:liked"})
            self.assertTrue(all(call.args[0] == "GET" for call in api.call_args_list))
            transport.assert_not_called()

    def test_missing_library_authorization_and_unknown_kinds_fail(self):
        with patch.object(service, "_get_valid_spotify_access_token", return_value="token"), \
             patch.object(service, "_spotify_api_request", return_value=(401, {}, "")):
            with self.assertRaises(service.HTTPException) as error:
                service.spotify_native_target("liked")
            self.assertEqual(error.exception.status_code, 401)
            with self.assertRaises(service.HTTPException): service.spotify_native_target("bad")
            with self.assertRaises(service.HTTPException): service.spotify_native_target("song", " ")


class SpotifyShuffleTests(unittest.TestCase):
    def test_standalone_shuffle_does_not_start_or_transfer_an_inactive_device(self):
        with patch.object(service, "_get_valid_spotify_access_token", return_value="token"), \
             patch.object(service, "_spotify_devices", return_value=[{"id": "device", "is_active": False}]), \
             patch.object(service, "_spotify_transport_action") as transport:
            with self.assertRaises(service.HTTPException): service.spotify_shuffle(False)
            transport.assert_not_called()

    def test_shuffle_is_an_explicit_idempotent_mode_on_the_target_device(self):
        for enabled in (True, False):
            with patch.object(service, "_ensure_spotify_active_device", return_value="device"), \
                 patch.object(service, "_spotify_api_request", return_value=(204, None, "")) as request, \
                 patch.object(service, "_spotify_playback_state", return_value={"device_id": "device", "shuffle_state": enabled}):
                result = service._spotify_set_shuffle("token", enabled)
                self.assertTrue(result["action_confirmed"])
                self.assertIs(result["shuffle_enabled"], enabled)
                self.assertEqual(request.call_args.kwargs["query"], {"state": str(enabled).lower(), "device_id": "device"})

    def test_unconfirmed_shuffle_does_not_report_success_or_restart_playback(self):
        with patch.object(service, "_spotify_transport_action", return_value={"device_id": "device"}), \
             patch.object(service, "_spotify_playback_state", return_value={"device_id": "device", "shuffle_state": False}) as state, \
             patch.object(service.time, "sleep"), patch.object(service, "_spotify_play") as play:
            with self.assertRaises(service.HTTPException) as error:
                service._spotify_set_shuffle("token", True)
            self.assertEqual(error.exception.status_code, 409)
            self.assertEqual(state.call_count, 3)
            play.assert_not_called()

    def test_playlist_shuffle_chooses_random_start_and_does_not_pollute_the_name(self):
        with patch.object(service, "_get_valid_spotify_access_token", return_value="token"), \
             patch.object(service, "_spotify_find_playlist_uri", return_value=("Gym", "spotify:playlist:abc")) as find, \
             patch.object(service, "_spotify_random_playlist_offset", return_value=17), \
             patch.object(service, "_spotify_play_with_shuffle", return_value={"status": "ok"}) as play:
            service.spotify_play_playlist(name="Gym", shuffle=True)
            find.assert_called_once_with("token", "Gym")
            play.assert_called_once_with("token", {"context_uri": "spotify:playlist:abc", "offset": {"position": 17}}, True, "play-playlist")

    def test_plain_playlist_play_preserves_existing_behavior(self):
        with patch.object(service, "_get_valid_spotify_access_token", return_value="token"), \
             patch.object(service, "_spotify_find_playlist_uri", return_value=("Gym", "spotify:playlist:abc")), \
             patch.object(service, "_spotify_play", return_value={"status": "ok"}) as play, \
             patch.object(service, "_spotify_set_shuffle") as shuffle:
            service.spotify_play_playlist(name="Gym")
            play.assert_called_once_with(token="token", body={"context_uri": "spotify:playlist:abc"}, action_label="play-playlist")
            shuffle.assert_not_called()

    def test_playlist_total_uses_current_endpoint_and_handles_empty(self):
        with patch.object(service, "_spotify_api_request", return_value=(200, {"total": 20}, "")) as request, \
             patch.object(service.random, "SystemRandom") as random:
            random.return_value.randrange.return_value = 7
            self.assertEqual(service._spotify_random_playlist_offset("token", "spotify:playlist:abc"), 7)
            self.assertEqual(request.call_args.args[1], "/v1/playlists/abc/items")
        with patch.object(service, "_spotify_api_request", return_value=(200, {"total": 0}, "")):
            with self.assertRaises(service.HTTPException): service._spotify_random_playlist_offset("token", "spotify:playlist:abc")

    def test_liked_shuffle_samples_beyond_the_newest_page_and_bounds_the_queue(self):
        offsets = []
        def request(method, path, token, query=None, body=None):
            offset = int(query["offset"]); offsets.append(offset)
            return 200, {"total": 2000, "items": [{"track": {"uri": f"spotify:track:{offset+i}"}} for i in range(50)]}, ""
        with patch.object(service, "_spotify_api_request", side_effect=request), \
             patch.object(service.random, "SystemRandom") as random:
            random.return_value.sample.return_value = [39, 20, 10, 5, 1]
            random.return_value.shuffle.side_effect = lambda values: values.reverse()
            uris = service._spotify_shuffled_liked_track_uris("token")
            self.assertEqual(len(uris), 50)
            self.assertEqual(offsets, [0, 1950, 1000, 500, 250, 50])
            self.assertEqual(uris[0], "spotify:track:99")

    def test_collection_confirmation_uses_matching_context_and_handles_partial_failure(self):
        with patch.object(service, "_spotify_play", return_value={"device_id": "device"}), \
             patch.object(service, "_spotify_set_shuffle", side_effect=service.HTTPException(status_code=403, detail="restriction")) as shuffle:
            with self.assertRaises(service.HTTPException) as error:
                service._spotify_play_with_shuffle("token", {"context_uri": "spotify:playlist:abc"}, True, "play-playlist")
            self.assertIn("Playback started", error.exception.detail)
            self.assertEqual(shuffle.call_args.kwargs["expected_context"], "spotify:playlist:abc")


if __name__ == "__main__": unittest.main()
