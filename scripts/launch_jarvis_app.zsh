#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

chmod +x "$ROOT_DIR/scripts/start_backend.sh"
chmod +x "$ROOT_DIR/scripts/package_jarvis_app.zsh"

"$ROOT_DIR/scripts/package_jarvis_app.zsh"
