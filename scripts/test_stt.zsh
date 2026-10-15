#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/macos_toolchain.zsh"
cargo test --locked --release --manifest-path "$ROOT_DIR/stt-core/Cargo.toml" "$@"
