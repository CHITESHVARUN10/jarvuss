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
swift build

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$BACKEND_DEST"

cp "$BUILD_DIR/jarvis" "$APP_MACOS/Jarvis"
chmod +x "$APP_MACOS/Jarvis"

cp "$ROOT_DIR/scripts/start_backend.sh" "$APP_MACOS/start_backend.sh"
chmod +x "$APP_MACOS/start_backend.sh"

cp "$BACKEND_SRC/voice_auth_service.py" "$BACKEND_DEST/voice_auth_service.py"
cp "$BACKEND_SRC/requirements.txt" "$BACKEND_DEST/requirements.txt"

if [[ -f "$BACKEND_SRC/embeddings.npy" ]]; then
  cp "$BACKEND_SRC/embeddings.npy" "$BACKEND_DEST/embeddings.npy"
fi

/usr/bin/python3 -m venv "$BACKEND_DEST/venv"
"$BACKEND_DEST/venv/bin/python" -m pip install --upgrade pip
"$BACKEND_DEST/venv/bin/python" -m pip install -r "$BACKEND_DEST/requirements.txt"

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
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Jarvis needs speech recognition access to transcribe your voice commands.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Jarvis controls supported apps (for media and automation) using Apple Events.</string>
</dict>
</plist>
PLIST

echo "Packaged app bundle: $APP_BUNDLE"
open "$APP_BUNDLE"
