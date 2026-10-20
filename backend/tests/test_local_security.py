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
from local_auth import HEADER, OAuthStates, create_token


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

    async def test_token_endpoint_never_returns_token_bytes(self):
        with patch.object(service.app.state, "auth_token", "test-token"), \
             patch.object(service, "_get_valid_spotify_access_token", return_value="private-access-token"):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=service.app), base_url="http://test") as client:
                response = await client.get("/spotify/token", headers={HEADER: "test-token"})
                self.assertEqual(response.status_code, 200)
                self.assertTrue(response.json()["access_token_present"])
                self.assertNotIn("private-access-token", response.text)

    async def test_oauth_callback_requires_single_use_state_before_token_exchange(self):
        states = OAuthStates()
        with patch.object(service, "_oauth_states", states), \
             patch.object(service, "_exchange_code_for_token", return_value={"access_token": "synthetic", "expires_in": 3600}) as exchange, \
             patch.object(service, "_store_spotify_tokens") as store:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=service.app), base_url="http://test") as client:
                self.assertEqual((await client.get("/spotify/callback", params={"code": "code"})).status_code, 400)
                exchange.assert_not_called()
                nonce = states.issue()
                response = await client.get("/spotify/callback", params={"code": "code", "state": nonce})
                self.assertEqual(response.status_code, 200)
                self.assertEqual((await client.get("/callback", params={"code": "code", "state": nonce})).status_code, 400)
                self.assertEqual(exchange.call_count, 1)
                self.assertEqual(store.call_count, 1)


class SecretFileTests(unittest.TestCase):
    def test_token_is_private_and_rotates_on_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "runtime"
            first = create_token(root)
            self.assertEqual((root / "backend_auth.token").read_text(), first)
            self.assertEqual(os.stat(root / "backend_auth.token").st_mode & 0o777, 0o600)
            self.assertNotEqual(create_token(root), first)

    def test_expired_oauth_nonce_is_refused(self):
        now = [1.0]
        states = OAuthStates(now=lambda: now[0])
        value = states.issue()
        now[0] += 601
        self.assertFalse(states.consume(value))

    def test_parallel_spotify_commands_refresh_only_once(self):
        calls = []
        def refresh():
            calls.append(True)
            time.sleep(0.02)
            service._store_spotify_tokens("new-token", "refresh", 3600)
            return "new-token"
        with patch.object(service, "spotify_tokens", {"access_token": "", "refresh_token": "", "expires_at": 0}), \
             patch.object(service, "_load_env_values", return_value={}), \
             patch.object(service, "_persist_env_updates"), \
             patch.object(service, "_refresh_spotify_token", side_effect=refresh):
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
                values = list(workers.map(lambda _: service._get_valid_spotify_access_token(), range(12)))
            self.assertEqual(values, ["new-token"] * 12)
            self.assertEqual(len(calls), 1)
