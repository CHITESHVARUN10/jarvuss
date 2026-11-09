"""Loopback API authentication.

The token rotates on backend startup. A same-user process able to read
Application Support is outside this boundary; the API never returns the token.
"""
import os
import secrets
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
