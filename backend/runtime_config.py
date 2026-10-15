"""Mutable settings live outside the app bundle; secrets live in Keychain.

Legacy .env files are read as data, never executed. Persisted UI settings take
precedence over launch-time defaults so saving a connection works immediately.
"""
from __future__ import annotations

import ctypes
import json
import os
import sys
import threading
from contextlib import ExitStack
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


class RuntimeConfig:
    def __init__(self, directory: Path | None = None, keychain=None) -> None:
        self.directory = directory or data_directory()
        self.path = self.directory / "connection_settings.json"
        self._keychain = keychain
        self._lock = threading.RLock()
        self._secrets: dict[str, str | None] = {}

    @property
    def keychain(self):
        if self._keychain is None:
            self._keychain = Keychain()
        return self._keychain

    def _settings(self) -> dict[str, str]:
        if not self.path.exists():
            return {}
        values = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(values, dict) or any(not isinstance(v, str) for v in values.values()):
            raise ValueError("Invalid Jarvis connection settings")
        return {k: v for k, v in values.items() if k not in SECRET_KEYS}

    def load(self, defaults: dict[str, str]) -> dict[str, str]:
        with self._lock:
            values = {**defaults, **self._settings()}
            for key in SECRET_KEYS:
                if key not in self._secrets:
                    self._secrets[key] = self.keychain.get(key)
                secret = self._secrets[key]
                if secret is None and values.get(key):
                    # Migrate existing local setup without changing its .env.
                    self.keychain.set(key, values[key])
                    secret = self._secrets[key] = values[key]
                if secret is not None:
                    values[key] = secret
            return values

    def save(self, updates: dict[str, str]) -> None:
        with self._lock:
            settings = self._settings()
            for key, value in updates.items():
                if key in SECRET_KEYS:
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
