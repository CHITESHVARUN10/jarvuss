#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/macos_toolchain.zsh"
TOOLS_DIR="$ROOT_DIR/.build/native-tools/venv"
if [[ -n "${JARVIS_BUILD_PYTHON:-}" ]]; then
  BUILD_PYTHON="$JARVIS_BUILD_PYTHON"
else
  # Retain the previous development environment outside the app before the
  # packaging cutover removes it from Resources. No user data is copied.
  if [[ ! -x "$TOOLS_DIR/bin/python" ]]; then
    PREVIOUS_TOOLS="$ROOT_DIR/.build/Jarvis.app/Contents/Resources/backend/venv"
    mkdir -p "$(dirname "$TOOLS_DIR")"
    if [[ -x "$PREVIOUS_TOOLS/bin/python" ]]; then
      ditto "$PREVIOUS_TOOLS" "$TOOLS_DIR"
    else
      PYTHON_BIN=""
      for candidate in /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 /opt/homebrew/bin/python3 /usr/bin/python3; do
        if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
          PYTHON_BIN="$candidate"
          break
        fi
      done
      if [[ -z "$PYTHON_BIN" ]]; then echo "Python 3.11+ is required for development/export tools." >&2; exit 1; fi
      "$PYTHON_BIN" -m venv "$TOOLS_DIR"
    fi
  fi
  BUILD_PYTHON="$TOOLS_DIR/bin/python"
  REQ_HASH="$(cat "$ROOT_DIR/backend/requirements.txt" "$ROOT_DIR/scripts/native-build-requirements.txt" | shasum -a 256 | awk '{print $1}')"
  CACHED_HASH="$(cat "$TOOLS_DIR/.native_req_hash" 2>/dev/null || true)"
  if [[ "$REQ_HASH" != "$CACHED_HASH" ]]; then
    "$BUILD_PYTHON" -m pip install -r "$ROOT_DIR/scripts/native-build-requirements.txt"
    echo "$REQ_HASH" > "$TOOLS_DIR/.native_req_hash"
  fi
fi
exec "$BUILD_PYTHON" "$ROOT_DIR/scripts/prepare_native_runtime.py" --destination "$ROOT_DIR/.build/native-runtime"
