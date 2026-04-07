#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/debug"
APP_BUNDLE="$ROOT_DIR/.build/Jarvis.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"
swift build

mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/jarvis" "$APP_MACOS/Jarvis"
chmod +x "$APP_MACOS/Jarvis"

cat > "$APP_PLIST" <<'PLIST'
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
</dict>
</plist>
PLIST

open "$APP_BUNDLE"
echo "Launched $APP_BUNDLE"
