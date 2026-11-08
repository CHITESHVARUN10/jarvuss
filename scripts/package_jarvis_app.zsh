#!/bin/zsh
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=26.0

REFRESH_FRONTEND=0
OPEN_APP=1
INSTALL_APP=0
for option in "$@"; do
  case "$option" in
    --refresh-app) REFRESH_FRONTEND=1 ;;
    --no-open) OPEN_APP=0 ;;
    --install) INSTALL_APP=1 ;;
    *) echo "Usage: $0 [--refresh-app] [--install] [--no-open]" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$ROOT_DIR/.build/Jarvis.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
BACKEND_SRC="$ROOT_DIR/backend"
BACKEND_DEST="$APP_RESOURCES/backend"

cd "$ROOT_DIR"

# A refresh reuses native cores and updates the app/helper/assets. Configuration
# import stays exclusive to a full package; development tools live outside the app.
if (( REFRESH_FRONTEND )); then
  if [[ ! -f "$APP_CONTENTS/Info.plist" || ! -d "$BACKEND_DEST" || ! -d "$ROOT_DIR/STTCore.xcframework" || ! -d "$ROOT_DIR/RustCore.xcframework" ]]; then
    echo "No complete existing bundle/native cores. Run full packaging first." >&2
    exit 1
  fi
fi
source "$ROOT_DIR/scripts/macos_toolchain.zsh"

./scripts/prepare_native_runtime.zsh

if (( ! REFRESH_FRONTEND )); then
# ── Rust STT core → STTCore.xcframework + Swift bridge (required by swift build) ──
./scripts/build_stt.sh --release
fi

# ── Rust command core → RustCore.xcframework + UniFFI bindings (linked into the app) ──
./scripts/build_rust_core.sh --release

swift build -c release --build-system native

# The helper is a separate executable so existing authenticated clients and
# OAuth redirect URLs keep their contract during the native transition.
cargo build --locked --release --manifest-path "$ROOT_DIR/rust-core/Cargo.toml" --bin jarvis-backend

NEW_BIN="$BUILD_DIR/jarvis"

# ── Always refresh the bundle binary — the cmp -s shortcut skips real
# rebuilds when only non-Swift inputs changed (bridge regen, Info.plist,
# embedded resources), leaving users on a stale binary that still logs
# old errors like "Missing NSMicrophoneUsageDescription".
mkdir -p "$APP_MACOS" "$BACKEND_DEST"
cp "$NEW_BIN" "$APP_MACOS/Jarvis"
cp "$ROOT_DIR/rust-core/target/release/jarvis-backend" "$APP_MACOS/JarvisBackend"
chmod +x "$APP_MACOS/JarvisBackend"
chmod +x "$APP_MACOS/Jarvis"

cp "$ROOT_DIR/scripts/start_backend.sh" "$APP_MACOS/start_backend.sh"
chmod +x "$APP_MACOS/start_backend.sh"

# Refresh builds must ship updated weights as well as updated app/helper code.
# Keep this outside dependency installation and configuration migration.
if [[ -d "$BACKEND_SRC/models" ]]; then
  mkdir -p "$BACKEND_DEST/models"
  echo "[Package] Syncing intent model ($(du -sh "$BACKEND_SRC/models" | awk '{print $1}'))..."
  rsync -a --delete "$BACKEND_SRC/models/" "$BACKEND_DEST/models/"
fi

if (( ! REFRESH_FRONTEND )); then
# Native configuration import runs after signing, below. Python never reads
# Keychain during packaging. Keep legacy bundle files until import succeeds.
RUNTIME_DATA_DIR="${JARVIS_DATA_DIR:-$HOME/Library/Application Support/Jarvis}"
case "$RUNTIME_DATA_DIR" in "~/"*) RUNTIME_DATA_DIR="$HOME/${RUNTIME_DATA_DIR:2}" ;; esac
mkdir -p "$RUNTIME_DATA_DIR"
if [[ ! -f "$RUNTIME_DATA_DIR/embeddings.npy" ]]; then
  if [[ -f "$BACKEND_DEST/embeddings.npy" ]]; then
    cp "$BACKEND_DEST/embeddings.npy" "$RUNTIME_DATA_DIR/embeddings.npy"
  elif [[ -f "$BACKEND_SRC/embeddings.npy" ]]; then
    cp "$BACKEND_SRC/embeddings.npy" "$RUNTIME_DATA_DIR/embeddings.npy"
  fi
fi
# Remove legacy generated bundle copies after migration.
# Legacy files are removed after the signed app imports them below.

fi # full configuration/profile migration

# Ship only native inference/audio libraries, verified voice assets and models.
# The old development Python environment was retained outside the bundle by
# prepare_native_runtime.zsh before this cleanup. User data lives elsewhere.
rm -rf "$BACKEND_DEST/venv" "$BACKEND_DEST/__pycache__" "$BACKEND_DEST/build" "$BACKEND_DEST/dist"
rm -f "$BACKEND_DEST"/*.py(N) "$BACKEND_DEST"/*.pyc(N) "$BACKEND_DEST/requirements.txt" "$BACKEND_DEST/main" "$BACKEND_DEST/main.spec"
mkdir -p "$APP_RESOURCES/native"
rsync -a --delete "$ROOT_DIR/.build/native-runtime/" "$APP_RESOURCES/native/"

# Copy the source-of-truth Info.plist into the bundle (mic usage string
# is what unlocks the macOS permission prompt — never `swift run`).
# Source: Sources/JarvisMacOS/Resources/Info.plist
cp "$ROOT_DIR/Sources/JarvisMacOS/Resources/Info.plist" "$APP_CONTENTS/Info.plist"

# Stamp source identity and verify the bundle contains the binary just built.
BUILD_REVISION="$(git rev-parse --short=12 HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  BUILD_REVISION="${BUILD_REVISION}+modified"
fi
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXECUTABLE_UUID="$(xcrun dwarfdump --uuid "$NEW_BIN" | awk '{print $2; exit}')"
BUNDLE_UUID="$(xcrun dwarfdump --uuid "$APP_MACOS/Jarvis" | awk '{print $2; exit}')"
if [[ -z "$EXECUTABLE_UUID" || "$EXECUTABLE_UUID" != "$BUNDLE_UUID" ]]; then
  echo "Packaged executable does not match the new build." >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Add :JarvisBuildRevision string $BUILD_REVISION" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :JarvisBuildTimestamp string $BUILD_TIMESTAMP" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :JarvisExecutableUUID string $EXECUTABLE_UUID" "$APP_CONTENTS/Info.plist"
echo "[Package] Source $BUILD_REVISION; binary $EXECUTABLE_UUID; built $BUILD_TIMESTAMP"

if [[ -f "$ROOT_DIR/Sources/JarvisMacOS/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Sources/JarvisMacOS/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

# Local command test runner (available only while test mode is enabled).
cp "$ROOT_DIR/htmls/command-test-runner.html" "$APP_RESOURCES/command-test-runner.html"
# Card typefaces (registered via ATSApplicationFontsPath = Fonts).
FONT_SRC="$ROOT_DIR/Sources/JarvisMacOS/Resources/Fonts"
if [[ -d "$FONT_SRC" ]]; then
  rm -rf "$APP_RESOURCES/Fonts"
  cp -R "$FONT_SRC" "$APP_RESOURCES/Fonts"
fi

# Re-sign AFTER all bundle contents are in place. macOS kills an app
# whose bundle signature no longer matches its executable ("Killed: 9" at
# launch) — which is exactly what a stale signature produces after a repackage.
#
# ── Signing identity and the Accessibility grant ────────────────────────────
# With an AD-HOC signature (`-`), the TCC (Accessibility) grant is keyed to the
# binary's cdhash — every repackage changes it, so the toggle stays ON in
# System Settings while `AXIsProcessTrusted()` returns false for the new
# build ("paste silently does nothing" after every rebuild). Signing with a
# STABLE identity (any real certificate) yields a designated requirement that
# outlives rebuilds, so the grant survives — the user re-adds the entry ONCE.
# Prefer any available code-signing identity; fall back to ad-hoc.
SIGN_IDENTITY="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"/ { print $2; exit }'
)"

sign_app() {
if [[ -n "${SIGN_IDENTITY:-}" ]] && codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "[Package] Signed $APP_BUNDLE with '$SIGN_IDENTITY' (stable — AX grant survives rebuilds)"
else
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 \
    && echo "[Package][WARN] Signed ad-hoc — the Accessibility grant will NOT survive rebuilds (re-add Jarvis in Privacy & Security → Accessibility after each package)" \
    || echo "[Package][WARN] codesign failed — app launch may be killed by Gatekeeper"
fi

}
sign_app

if (( ! REFRESH_FRONTEND )); then
  for ENV_SOURCE in "$BACKEND_DEST/.env" "$ROOT_DIR/.env"; do
    if [[ -f "$ENV_SOURCE" ]]; then
      "$APP_MACOS/Jarvis" --import-env "$ENV_SOURCE"
    fi
  done
  if [[ -f "$BACKEND_DEST/.env" || -f "$BACKEND_DEST/embeddings.npy" ]]; then
    rm -f "$BACKEND_DEST/.env" "$BACKEND_DEST/embeddings.npy"
    sign_app
  fi
fi

codesign --verify --deep "$APP_BUNDLE"
if (( INSTALL_APP )); then
  # Never replace executable pages under a running process. Quit normally so
  # state and the clean-exit marker are saved before copying the new bundle.
  if pgrep -x Jarvis >/dev/null; then
    osascript -e 'tell application id "local.jarvis.macos" to quit'
    for attempt in {1..50}; do
      if ! pgrep -x Jarvis >/dev/null; then break; fi
      sleep 0.1
    done
    if pgrep -x Jarvis >/dev/null; then
      echo "Jarvis is still running. Quit it before installing." >&2
      exit 1
    fi
  fi
  ditto "$APP_BUNDLE" /Applications/Jarvis.app
  codesign --verify --deep /Applications/Jarvis.app
  INSTALLED_UUID="$(xcrun dwarfdump --uuid /Applications/Jarvis.app/Contents/MacOS/Jarvis | awk '{print $2; exit}')"
  if [[ "$INSTALLED_UUID" != "$EXECUTABLE_UUID" ]]; then
    echo "Installed executable does not match the verified build." >&2
    exit 1
  fi
  APP_BUNDLE=/Applications/Jarvis.app
  echo "[Package] Installed and verified $INSTALLED_UUID in /Applications"
fi
echo "Packaged app bundle: $APP_BUNDLE"
if (( OPEN_APP )); then open "$APP_BUNDLE"; fi
