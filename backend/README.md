# Jarvis local services and Python reference

The packaged app uses `JarvisBackend`, the native Rust helper. Voice enrollment,
verification, Spotify metadata/OAuth, connection management and intent inference
run without a Python interpreter. Native Spotify playback and macOS adapters
remain in Swift. The app requires macOS 26.0 or later.

`voice_auth_service.py` remains a development reference for differential tests,
model export and optional legacy Web API playback endpoints. These Python
endpoints are not included in the native app bundle. App-facing lookup routes
are implemented by Rust; the app never uses Web API playback writes.

See [migration, compatibility and benchmark evidence](../docs/native-runtime-migration.md).

## Run the development reference

From the repository root:

```zsh
python3 -m venv backend/venv
backend/venv/bin/pip install -r backend/requirements.txt
backend/venv/bin/python -m uvicorn voice_auth_service:app --app-dir backend --host 127.0.0.1 --port 8000
```

Use `scripts/package_jarvis_app.zsh` to build and provision the packaged app.
Its build-time export and verification environment lives outside the signed
bundle; it never installs a venv in Application Support at app startup.

Voice embeddings and non-secret connection settings are stored in
`~/Library/Application Support/Jarvis` (`JARVIS_DATA_DIR` overrides). Secrets
use macOS Keychain, service `local.jarvis.credentials`. App-managed helpers delegate
credential reads and refreshed-token writes to the signed Jarvis process over a
private Unix socket authenticated with a per-launch token. Credentials never go
into command arguments, environment variables, settings JSON, or socket files.
Only the socket location and a temporary channel nonce are passed in the helper's environment.
Values are cached in memory and invalidated after connection settings change.
Only the requested service's secrets are loaded. Standalone Python Keychain
access is noninteractive: use the app-managed helper for protected credentials.
The health handshake identifies the owning app process, so helpers left behind
by a previous app session are restarted instead of reusing a dead credential link.
Existing `.env` files
are read literally as migration defaults, never sourced or rewritten. Saved
connection settings take precedence over legacy values and inherited defaults.

Enrollment, verification and reset run through a bounded, single-worker queue.
The encoder loads on first voice use. `/health` and other routes remain
responsive during voice inference. The intent parser falls back explicitly
when its token limit is exceeded; it does not execute a truncated request.

Lightweight regression tests require no speech models or Keychain access:

```zsh
python3 -m venv /tmp/jarvis-tests
/tmp/jarvis-tests/bin/pip install -r backend/requirements-test.txt
/tmp/jarvis-tests/bin/python -B -m unittest discover -s backend/tests -v
```

See the root README for the endpoint list and isolated PostgreSQL test.
