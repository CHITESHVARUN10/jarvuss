#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/debug"
APP_BUNDLE="$ROOT_DIR/.build/Jarvis.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
BACKEND_SRC="$ROOT_DIR/backend"
BACKEND_DEST="$APP_RESOURCES/backend"

USE_PYINSTALLER="${JARVIS_USE_PYINSTALLER:-0}"

cd "$ROOT_DIR"

# Load repo .env (PG*, Spotify) so the launched app inherits them.
# (Finder-launched apps don't read shell dotfiles; `open` inherits this env.)
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

# ── Rust STT core → STTCore.xcframework + Swift bridge (required by swift build) ──
./scripts/build_stt.sh --release

swift build

NEW_BIN="$BUILD_DIR/jarvis"

# ── Always refresh the bundle binary — the cmp -s shortcut skips real
# rebuilds when only non-Swift inputs changed (bridge regen, Info.plist,
# embedded resources), leaving users on a stale binary that still logs
# old errors like "Missing NSMicrophoneUsageDescription".
mkdir -p "$APP_MACOS" "$BACKEND_DEST"
cp "$NEW_BIN" "$APP_MACOS/Jarvis"
chmod +x "$APP_MACOS/Jarvis"

cp "$ROOT_DIR/scripts/start_backend.sh" "$APP_MACOS/start_backend.sh"
chmod +x "$APP_MACOS/start_backend.sh"

cp "$BACKEND_SRC"/*.py "$BACKEND_DEST/"
cp "$BACKEND_SRC/requirements.txt" "$BACKEND_DEST/requirements.txt"
# The Swift app + Python backend both fall back to a bundled .env when the
# launch environment lacks PG*/Spotify keys (Finder/`open` doesn't inherit
# shell exports). The backend resolves PROJECT_ROOT/.env in dev and the
# bundled copy in the app; DBManager reads the same file.
if [[ -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env" "$BACKEND_DEST/.env"
fi

if [[ -f "$BACKEND_SRC/embeddings.npy" ]]; then
  cp "$BACKEND_SRC/embeddings.npy" "$BACKEND_DEST/embeddings.npy"
fi

# ── Python venv: create once, reinstall only if requirements changed ──────
REQ_HASH_FILE="$BACKEND_DEST/venv/.req_hash"

if [[ -x "$BACKEND_DEST/venv/bin/python" ]] && ! "$BACKEND_DEST/venv/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  echo "[Package] Existing venv is Python < 3.10 — recreating..."
  rm -rf "$BACKEND_DEST/venv"
fi

if [[ ! -x "$BACKEND_DEST/venv/bin/python" ]]; then
  echo "[Package] Creating Python venv..."
  # Prefer Homebrew Python (>=3.10): /usr/bin/python3 is Apple-shipped 3.9,
  # which cannot evaluate `X | Y` type annotations at runtime.
  PYBIN=""
  for candidate in /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      PYBIN="$candidate"
      break
    fi
  done
  "${PYBIN:-/usr/bin/python3}" -m venv "$BACKEND_DEST/venv"
fi

REQ_HASH="$(shasum -a 256 "$BACKEND_DEST/requirements.txt" | awk '{print $1}')"
CACHED_HASH=""
if [[ -f "$REQ_HASH_FILE" ]]; then
  CACHED_HASH="$(cat "$REQ_HASH_FILE" 2>/dev/null || true)"
fi

if [[ "$REQ_HASH" != "$CACHED_HASH" ]]; then
  echo "[Package] requirements.txt changed — running pip install (this takes a moment)..."
  "$BACKEND_DEST/venv/bin/python" -m pip install --upgrade pip --quiet
  "$BACKEND_DEST/venv/bin/python" -m pip install -r "$BACKEND_DEST/requirements.txt" --quiet
  echo "$REQ_HASH" > "$REQ_HASH_FILE"
  echo "[Package] pip install complete."
else
  echo "[Package] Dependencies unchanged — skipping pip install."
fi

cat > "$BACKEND_DEST/main.py" <<'PY'
from uvicorn import run

if __name__ == "__main__":
    run("voice_auth_service:app", host="127.0.0.1", port=8000)
PY

if [[ "$USE_PYINSTALLER" == "1" ]]; then
  "$BACKEND_DEST/venv/bin/python" -m pip install pyinstaller
  pushd "$BACKEND_DEST" >/dev/null
  "$BACKEND_DEST/venv/bin/pyinstaller" --onefile --name main main.py
  cp "$BACKEND_DEST/dist/main" "$BACKEND_DEST/main"
  chmod +x "$BACKEND_DEST/main"
  rm -rf "$BACKEND_DEST/build" "$BACKEND_DEST/dist" "$BACKEND_DEST/main.spec"
  popd >/dev/null
fi

# Keep in sync with Sources/JarvisMacOS/Resources/Info.plist (source of truth).
# The heredoc below regenerates it into the bundle; edit the source file, then
# mirror the change here.
cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Jarvis</string>
    <key>CFBundleIdentifier</key>
    <string>local.jarvis.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Jarvis</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Jarvis needs microphone access to detect speech and execute voice commands.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Jarvis controls supported apps (for media and automation) using Apple Events.</string>
</dict>
</plist>
PLIST

echo "Packaged app bundle: $APP_BUNDLE"
open "$APP_BUNDLE"
