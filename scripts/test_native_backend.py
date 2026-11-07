#!/usr/bin/env python3
"""Isolated native-helper integration tests. Uses temporary settings, synthetic
credentials and an ephemeral loopback port. Never touches user connections,
enrollments, Keychain, Spotify, PostgreSQL, or the installed/running app.
"""
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
VOICE_ASSETS = Path(os.environ.get("JARVIS_NATIVE_TEST_VOICE", ROOT / ".build/native-voice"))
RUNTIME_ASSETS = Path(os.environ.get("JARVIS_NATIVE_TEST_RUNTIME", ROOT / ".build/native-runtime"))


class NativeBackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="jarvis-native-test-")
        cls.root = Path(cls.tmp.name)
        cls.data = cls.root / "data"
        cls.data.mkdir()
        cls.backend = cls.root / "backend"
        cls.backend.mkdir()
        for path in (ROOT / "backend").glob("*.py"):
            shutil.copy2(path, cls.backend / path.name)
        # Share dependencies read-only; all mutable data stays in the temp root.
        venv = ROOT / ".build/Jarvis.app/Contents/Resources/backend/venv"
        (cls.backend / "venv").symlink_to(venv, target_is_directory=True)
        native = cls.root / "native"
        native.mkdir()
        (native / "voice").symlink_to(VOICE_ASSETS, target_is_directory=True)
        (native / "libonnxruntime.1.31.0.dylib").symlink_to(RUNTIME_ASSETS / "libonnxruntime.1.31.0.dylib")
        cls.secrets = {}

        class Broker(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline(65537))
                if request.get("token") != "synthetic-broker-token":
                    self.wfile.write(b'{"ok":false}\n')
                    return
                if request["operation"] == "get":
                    result = {"ok": True, "values": {key: cls.secrets.get(key) for key in request["keys"]}}
                else:
                    cls.secrets.update(request["values"])
                    result = {"ok": True}
                self.wfile.write(json.dumps(result).encode() + b"\n")

        cls.broker = socketserver.ThreadingUnixStreamServer(str(cls.root / "broker.sock"), Broker)
        cls.broker_thread = threading.Thread(target=cls.broker.serve_forever, daemon=True)
        cls.broker_thread.start()
        env = {"PATH": os.environ["PATH"], "HOME": str(Path.home()),
               "JARVIS_DATA_DIR": str(cls.data), "JARVIS_BACKEND_PORT": "0",
               "JARVIS_CREDENTIAL_SOCKET": str(cls.root / "broker.sock"),
               "JARVIS_CREDENTIAL_TOKEN": "synthetic-broker-token",
               "PYTHONDONTWRITEBYTECODE": "1"}
        cls.log = (cls.root / "helper.log").open("w+")
        cls.process = subprocess.Popen([str(ROOT / "rust-core/target/release/jarvis-backend"),
                                        "--backend-dir", str(cls.backend)], env=env,
                                       stdout=cls.log, stderr=cls.log)
        deadline = time.monotonic() + 15
        cls.port = None
        while time.monotonic() < deadline:
            cls.log.flush()
            match = re.search(r"ready port=(\d+)", (cls.root / "helper.log").read_text())
            if match:
                cls.port = int(match[1])
                break
            if cls.process.poll() is not None:
                raise RuntimeError("Isolated native helper exited")
            time.sleep(0.02)
        if cls.port is None:
            raise RuntimeError("Isolated native helper did not start")
        cls.token = (cls.data / "backend_auth.token").read_text()

    @classmethod
    def tearDownClass(cls):
        cls.process.send_signal(signal.SIGTERM)
        cls.process.wait(timeout=10)
        cls.log.close()
        cls.broker.shutdown()
        cls.broker.server_close()
        cls.tmp.cleanup()

    def request(self, method, path, payload=None, authenticated=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["X-Jarvis-Token"] = self.token
        connection.request(method, path, None if payload is None else json.dumps(payload), headers)
        response = connection.getresponse()
        status, body = response.status, response.read()
        connection.close()
        return status, json.loads(body or b"null")

    def test_unauthenticated_requests_cannot_read_or_mutate(self):
        for method, path in [("GET", "/health"), ("GET", "/spotify/token"),
                             ("POST", "/postgres/credentials"), ("POST", "/reset"),
                             ("POST", "/parse_intent")]:
            self.assertEqual(self.request(method, path, {}, False)[0], 401)

    def test_health_runs_without_python_worker(self):
        status, result = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(result["runtime"], "rust")
        self.assertEqual(result["api_version"], 4)

    def test_postgres_contract_preserves_password(self):
        values = dict(host="localhost", port="", database="synthetic", user="example", password="fake-password")
        self.assertEqual(self.request("POST", "/postgres/credentials", values)[0], 200)
        values["password"] = ""
        self.assertEqual(self.request("POST", "/postgres/credentials", values)[0], 200)
        status, result = self.request("GET", "/postgres/status")
        self.assertEqual(status, 200)
        self.assertEqual(result["port"], "5432")
        self.assertTrue(result["password_present"])
        self.assertTrue(result["configured"])
        self.assertNotIn("fake-password", json.dumps(result))
        self.assertNotIn("fake-password", (self.data / "connection_settings.json").read_text())

    def test_spotify_contract_state_and_secret_reset(self):
        self.assertEqual(self.request("POST", "/spotify/credentials", {"client_id": "id", "client_secret": "synthetic"})[0], 200)
        status, result = self.request("GET", "/spotify/status")
        self.assertEqual(status, 200)
        self.assertTrue(result["client_secret_present"])
        self.assertFalse(result["access_token_present"])
        self.assertNotIn("synthetic", json.dumps(result))
        status, result = self.request("GET", "/spotify/connect-url")
        self.assertEqual(status, 200)
        from urllib.parse import urlparse, parse_qs
        query = parse_qs(urlparse(result["url"]).query)
        self.assertEqual(query["client_id"], ["id"])
        # Missing code consumes state without ever contacting Spotify.
        state = query["state"][0]
        status, result = self.request("GET", "/spotify/callback?state=" + state, authenticated=False)
        self.assertEqual(status, 400)
        self.assertIn("missing code", result["detail"])
        status, result = self.request("GET", "/callback?state=" + state, authenticated=False)
        self.assertEqual(status, 400)
        self.assertIn("Invalid or expired", result["detail"])

    def test_native_voice_does_not_rotate_public_token(self):
        status, result = self.request("GET", "/stats")
        self.assertEqual(status, 200)
        self.assertEqual(result, {"enrolled_count": 0})
        self.assertEqual((self.data / "backend_auth.token").read_text(), self.token)
        self.assertEqual(self.request("POST", "/reset", {})[0], 200)
        self.assertEqual(self.request("GET", "/stats")[1], {"enrolled_count": 0})
        self.assertNotEqual(subprocess.run(["pgrep", "-P", str(self.process.pid)], capture_output=True).returncode, 0,
                            "Native stats/reset must not launch Python")

    def test_voice_enrollment_verification_and_old_profile_compatibility(self):
        corpus = VOICE_ASSETS / "parity-formats.json"
        if not corpus.exists():
            self.skipTest("Run the synthetic voice differential comparison first")
        report = json.loads(corpus.read_text())
        source = next(r for r in report["records"] if r["fixture"] == "samantha-normal.wav")
        comparison = next(r for r in report["profile_decisions"]
                          if r["candidate"] == "daniel-normal.wav" and r["profile"] == "samantha-normal.wav")
        import struct
        header = "{'descr': '<f4', 'fortran_order': False, 'shape': (1, 256), }"
        header += " " * ((64 - (10 + len(header) + 1) % 64) % 64) + "\n"
        (self.data / "embeddings.npy").write_bytes(b"\x93NUMPY\x01\x00" + struct.pack("<H", len(header))
                                                 + header.encode() + struct.pack("<256f", *source["reference"]))
        def audio_request(endpoint, fixture):
            boundary = "SyntheticAudioBoundary"
            data = (VOICE_ASSETS / "variants" / fixture).read_bytes()
            body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="sample.wav"\r\n'
                    'Content-Type: audio/wav\r\n\r\n').encode() + data + f"\r\n--{boundary}--\r\n".encode()
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
            connection.request("POST", "/" + endpoint, body,
                               {"X-Jarvis-Token": self.token, "Content-Type": "multipart/form-data; boundary=" + boundary})
            response = connection.getresponse()
            status, result = response.status, json.loads(response.read())
            connection.close()
            return status, result
        try:
            status, result = audio_request("verify", "daniel-normal.wav")
            self.assertEqual(status, 200, result)
            self.assertEqual(result["confidence"], comparison["reference"]["confidence"])
            self.assertAlmostEqual(result["similarity"], comparison["reference"]["similarity"], places=4)
            self.assertEqual(audio_request("enroll", "samantha-normal.wav"), (200, {"enrolled_count": 2}))
            self.assertEqual(self.request("GET", "/stats")[1], {"enrolled_count": 2})
            self.assertNotEqual(subprocess.run(["pgrep", "-P", str(self.process.pid)], capture_output=True).returncode, 0,
                                "Native enrollment and verification must not launch Python")
        finally:
            self.request("POST", "/reset", {})


if __name__ == "__main__":
    unittest.main()
