"""API tests use synthetic secrets and never access the user's Keychain."""
import concurrent.futures
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import httpx
import voice_auth_service as service
from local_auth import HEADER, create_token


class LocalAuthTests(unittest.IsolatedAsyncioTestCase):
    async def test_unauthenticated_requests_cannot_read_or_mutate_state(self):
        with patch.object(service.app.state, "auth_token", "test-token"), \
             patch.object(service, "_persist_env_updates") as save:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=service.app), base_url="http://test") as client:
                for path in ["/health", "/spotify/token", "/spotify/status", "/docs"]:
                    self.assertEqual((await client.get(path)).status_code, 401)
                for path in ["/postgres/credentials", "/spotify/credentials", "/reset", "/verify", "/parse_intent"]:
                    self.assertEqual((await client.post(path, json={})).status_code, 401)
                response = await client.get("/health", headers={HEADER: "test-token"})
                self.assertEqual(response.status_code, 200)
            save.assert_not_called()

    async def test_removed_spotify_routes_are_unavailable(self):
        with patch.object(service.app.state, "auth_token", "test-token"):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=service.app), base_url="http://test") as client:
                for path in ["/spotify/status", "/spotify/token", "/spotify/native-target", "/spotify/callback", "/callback"]:
                    self.assertEqual((await client.get(path, headers={HEADER: "test-token"})).status_code, 404)
                    self.assertEqual((await client.get(path)).status_code, 401)
                self.assertEqual((await client.post("/spotify/credentials", json={}, headers={HEADER: "test-token"})).status_code, 404)


class SecretFileTests(unittest.TestCase):
    def test_token_is_private_and_rotates_on_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "runtime"
            first = create_token(root)
            self.assertEqual((root / "backend_auth.token").read_text(), first)
            self.assertEqual(os.stat(root / "backend_auth.token").st_mode & 0o777, 0o600)
            self.assertNotEqual(create_token(root), first)
