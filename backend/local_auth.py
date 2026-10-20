"""Loopback API authentication and single-use browser OAuth state.

The token rotates on backend startup. A same-user process able to read
Application Support is outside this boundary; the API never returns the token.
"""
import os
import secrets
import threading
import time
from pathlib import Path
from tempfile import NamedTemporaryFile

HEADER = "X-Jarvis-Token"


def create_token(directory: Path) -> str:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    token = secrets.token_urlsafe(32)
    temporary = None
    try:
        with NamedTemporaryFile(mode="w", encoding="ascii", dir=directory,
                                prefix=".backend-auth-", delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            handle.write(token)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, directory / "backend_auth.token")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return token


def authorized(expected: str | None, supplied: str | None) -> bool:
    return bool(expected and supplied and secrets.compare_digest(expected.encode(), supplied.encode()))


class OAuthStates:
    def __init__(self, now=time.monotonic):
        self._now = now
        self._lock = threading.Lock()
        self._pending: dict[str, float] = {}

    def issue(self) -> str:
        with self._lock:
            now = self._now()
            self._pending = {key: expiry for key, expiry in self._pending.items() if expiry > now}
            if len(self._pending) >= 32:
                self._pending.pop(next(iter(self._pending)))
            value = secrets.token_urlsafe(32)
            self._pending[value] = now + 600
            return value

    def consume(self, value: str | None) -> bool:
        with self._lock:
            return self._pending.pop(value or "", 0) > self._now()
