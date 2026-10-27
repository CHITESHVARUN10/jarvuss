"""Mutable settings live outside the app bundle; secrets live in Keychain.

Legacy .env files are read as data, never executed. Persisted UI settings take
precedence over launch-time defaults so saving a connection works immediately.
"""
from __future__ import annotations

import ctypes
import json
import os
import socket
import fcntl
import sys
import threading
from contextlib import ExitStack, contextmanager
from pathlib import Path
from tempfile import NamedTemporaryFile

KEYCHAIN_SERVICE = "local.jarvis.credentials"
SECRET_KEYS = frozenset({"PGPASSWORD", "SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN"})
CONNECTION_KEYS = SECRET_KEYS | {"PGHOST", "PGPORT", "PGDATABASE", "PGUSER",
                                "SPOTIFY_CLIENT_ID", "SPOTIFY_REDIRECT_URI", "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT"}


def data_directory() -> Path:
    return Path(os.environ.get("JARVIS_DATA_DIR", "~/Library/Application Support/Jarvis")).expanduser()


def read_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] in ("'", '"') and value[-1] == value[0]:
            value = value[1:-1]
        if key.strip():
            result[key.strip()] = value
    return result


class Keychain:
    """Security.framework bindings; secret values never enter process arguments."""

    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise RuntimeError("Jarvis credential storage requires macOS Keychain")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        ptr = ctypes.c_void_p
        signatures = {
            "CFStringCreateWithCString": ([ptr, ctypes.c_char_p, ctypes.c_uint32], ptr),
            "CFDataCreate": ([ptr, ptr, ctypes.c_long], ptr),
            "CFDataGetLength": ([ptr], ctypes.c_long),
            "CFDataGetBytePtr": ([ptr], ptr),
            "CFDictionaryCreateMutable": ([ptr, ctypes.c_long, ptr, ptr], ptr),
            "CFDictionarySetValue": ([ptr, ptr, ptr], None),
            "CFRelease": ([ptr], None),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.cf, name)
            function.argtypes, function.restype = args, result
        for name in ("SecItemCopyMatching", "SecItemAdd", "SecItemUpdate"):
            function = getattr(self.sec, name)
            function.argtypes, function.restype = [ptr, ptr], ctypes.c_int32

    def _constant(self, name: str, library=None):
        return ctypes.c_void_p.in_dll(library or self.sec, name).value

    def _query(self, stack: ExitStack, account: str):
        def own(value):
            if not value:
                raise RuntimeError("Could not allocate Keychain query")
            stack.callback(self.cf.CFRelease, value)
            return value

        # Null dictionary callbacks: all referenced CF objects are held by
        # ExitStack until the synchronous Security call has completed.
        query = own(self.cf.CFDictionaryCreateMutable(None, 0, None, None))
        self.cf.CFDictionarySetValue(query, self._constant("kSecClass"), self._constant("kSecClassGenericPassword"))
        self.cf.CFDictionarySetValue(query, self._constant("kSecUseAuthenticationUI"),
                                   self._constant("kSecUseAuthenticationUIFail"))
        for key, value in (("kSecAttrService", KEYCHAIN_SERVICE), ("kSecAttrAccount", account)):
            string = own(self.cf.CFStringCreateWithCString(None, value.encode("utf-8"), 0x08000100))
            self.cf.CFDictionarySetValue(query, self._constant(key), string)
        return query, own

    def get(self, account: str) -> str | None:
        with ExitStack() as stack:
            query, _ = self._query(stack, account)
            self.cf.CFDictionarySetValue(query, self._constant("kSecReturnData"),
                                       self._constant("kCFBooleanTrue", self.cf))
            result = ctypes.c_void_p()
            status = self.sec.SecItemCopyMatching(query, ctypes.byref(result))
            if status == -25300:  # errSecItemNotFound
                return None
            if status != 0:
                raise RuntimeError(f"Keychain read failed ({status})")
            stack.callback(self.cf.CFRelease, result.value)
            return ctypes.string_at(self.cf.CFDataGetBytePtr(result),
                                    self.cf.CFDataGetLength(result)).decode("utf-8")

    def set(self, account: str, value: str) -> None:
        with ExitStack() as stack:
            query, own = self._query(stack, account)
            encoded = value.encode("utf-8")
            raw = ctypes.create_string_buffer(encoded)
            data = own(self.cf.CFDataCreate(None, raw, len(encoded)))
            updates = own(self.cf.CFDictionaryCreateMutable(None, 0, None, None))
            self.cf.CFDictionarySetValue(updates, self._constant("kSecValueData"), data)
            status = self.sec.SecItemUpdate(query, updates)
            if status == -25300:
                self.cf.CFDictionarySetValue(query, self._constant("kSecValueData"), data)
                status = self.sec.SecItemAdd(query, None)
            if status != 0:
                raise RuntimeError(f"Keychain write failed ({status})")


class AppCredentialStore:
    """Per-launch local IPC. Only the signed Jarvis process touches Keychain."""
    def __init__(self, path: str, token: str):
        if not path or not token:
            raise RuntimeError("Start Jarvis to access saved credentials")
        self.path, self.token = path, token

    def _request(self, operation: str, **fields):
        payload = json.dumps({"token": self.token, "operation": operation, **fields}).encode() + b"\n"
        if len(payload) > 65536:
            raise RuntimeError("Credential request is too large")
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(90)
                connection.connect(self.path)
                connection.sendall(payload)
                reply = bytearray()
                while len(reply) <= 65536 and b"\n" not in reply:
                    chunk = connection.recv(min(4096, 65537 - len(reply)))
                    if not chunk:
                        break
                    reply.extend(chunk)
            if len(reply) > 65536:
                raise ValueError("response too large")
            result = json.loads(reply)
            if not isinstance(result, dict) or result.get("ok") is not True:
                raise ValueError("credentials unavailable")
            return result
        except (OSError, ValueError):
            raise RuntimeError("Saved credentials are unavailable. Open Jarvis and unlock your login Keychain or update Connections.") from None

    def get_many(self, keys):
        if not set(keys) <= SECRET_KEYS:
            raise ValueError("Unsupported credential")
        values = self._request("get", keys=list(keys)).get("values")
        if not isinstance(values, dict) or any(v is not None and not isinstance(v, str) for v in values.values()):
            raise RuntimeError("Invalid credential response")
        return {key: values.get(key) for key in keys}

    def get(self, key):
        return self.get_many([key])[key]

    def set_many(self, values):
        if not set(values) <= SECRET_KEYS:
            raise ValueError("Unsupported credential")
        self._request("set", values=values)

    def set(self, key, value):
        self.set_many({key: value})


class RuntimeConfig:
    def __init__(self, directory: Path | None = None, keychain=None) -> None:
        self.directory = directory or data_directory()
        self.path = self.directory / "connection_settings.json"
        self._keychain = keychain
        self._lock = threading.RLock()
        self._secrets: dict[str, str | None] = {}
        self._revision = None

    @property
    def keychain(self):
        if self._keychain is None:
            path = os.environ.get("JARVIS_CREDENTIAL_SOCKET", "")
            token = os.environ.get("JARVIS_CREDENTIAL_TOKEN", "")
            self._keychain = AppCredentialStore(path, token) if path or token else Keychain()
        return self._keychain

    def _settings(self) -> dict[str, str]:
        if not self.path.exists():
            return {}
        values = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(values, dict) or any(not isinstance(v, str) for v in values.values()):
            raise ValueError("Invalid Jarvis connection settings")
        return {k: v for k, v in values.items() if k not in SECRET_KEYS}

    def _signature(self):
        try:
            stat = self.path.stat()
            return stat.st_ino, stat.st_mtime_ns, stat.st_size
        except FileNotFoundError:
            return None

    def _refresh_cache(self):
        current = self._signature()
        if current != self._revision:
            self._secrets.clear()
            self._revision = current

    def load(self, defaults: dict[str, str], secret_keys=SECRET_KEYS) -> dict[str, str]:
        if not set(secret_keys) <= SECRET_KEYS:
            raise ValueError("Unsupported credential")
        with self._lock:
            self._refresh_cache()
            values = {**defaults, **self._settings()}
            missing = [key for key in secret_keys if key not in self._secrets]
            if missing:
                fetched = self.keychain.get_many(missing) if hasattr(self.keychain, "get_many") else {
                    key: self.keychain.get(key) for key in missing}
                self._secrets.update(fetched)
            for key in secret_keys:
                secret = self._secrets.get(key)
                if secret is None and values.get(key):
                    self.keychain.set(key, values[key])
                    secret = self._secrets[key] = values[key]
                if secret is not None:
                    values[key] = secret
            return values

    @contextmanager
    def _write_lock(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(self.directory / "connection_settings.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def save(self, updates: dict[str, str]) -> None:
        with self._lock, self._write_lock():
            self._refresh_cache()
            settings = self._settings()
            secrets = {key: value for key, value in updates.items() if key in SECRET_KEYS}
            if secrets and hasattr(self.keychain, "set_many"):
                self.keychain.set_many(secrets)
            for key, value in updates.items():
                if key in SECRET_KEYS:
                    if not hasattr(self.keychain, "set_many"):
                        self.keychain.set(key, value)
                    self._secrets[key] = value
                else:
                    settings[key] = value
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            temp_path = None
            try:
                with NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.directory,
                                        prefix=".settings-", delete=False) as handle:
                    temp_path = Path(handle.name)
                    json.dump(settings, handle, ensure_ascii=False)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temp_path, self.path)
                self._revision = self._signature()
            finally:
                if temp_path is not None:
                    temp_path.unlink(missing_ok=True)

    def import_defaults(self, defaults: dict[str, str]) -> None:
        # A developer's .env may also contain unrelated services' secrets.
        # Import only the connection keys Jarvis actually owns.
        with self._lock:
            supported = {key: value for key, value in defaults.items() if key in CONNECTION_KEYS}
            self.load(supported)
            existing = self._settings()
            self.save({key: value for key, value in supported.items()
                       if key not in SECRET_KEYS and key not in existing})


if __name__ == "__main__":
    # Packaging imports developer configuration without copying secrets into
    # the signed app. No shell evaluation or third-party dependencies.
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--import-env", type=Path, required=True)
    args = parser.parse_args()
    RuntimeConfig().import_defaults(read_env(args.import_env))
