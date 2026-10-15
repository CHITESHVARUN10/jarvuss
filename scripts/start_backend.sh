#!/bin/zsh
set -euo pipefail

# Bytecode caches written into Resources/backend at runtime break the
# bundle's code-signature seal; keep the venv import-cache-free.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$SCRIPT_DIR/../Resources/backend" ]]; then
  BACKEND_DIR="$(cd "$SCRIPT_DIR/../Resources/backend" && pwd)"
else
  BACKEND_DIR="$(cd "$SCRIPT_DIR/../backend" && pwd)"
fi
BUNDLED_VENV_DIR="$BACKEND_DIR/venv"
REQ_FILE="$BACKEND_DIR/requirements.txt"
PID_DIR="${JARVIS_DATA_DIR:-$HOME/Library/Application Support/Jarvis}"
case "$PID_DIR" in "~/"*) PID_DIR="$HOME/${PID_DIR:2}" ;; esac
PID_FILE="$PID_DIR/backend.pid"
LOG_DIR="$PID_DIR/logs"
LOG_FILE="$LOG_DIR/backend.log"
PIP_LOG_FILE="$LOG_DIR/backend-pip.log"
HOST="127.0.0.1"
PORT="8000"

mkdir -p "$PID_DIR" "$LOG_DIR"

# Configuration is parsed by runtime_config.py; never source app-written data.
export JARVIS_DATA_DIR="$PID_DIR"

is_pid_running() {
  local pid="$1"
  if [[ -z "$pid" ]]; then
    return 1
  fi
  kill -0 "$pid" >/dev/null 2>&1
}

is_port_open() {
  nc -z "$HOST" "$PORT" >/dev/null 2>&1
}

if [[ -f "$PID_FILE" ]]; then
  existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if is_pid_running "$existing_pid"; then
    exit 0
  fi
  rm -f "$PID_FILE"
fi

if is_port_open; then
  exit 0
fi

if [[ -x "$BACKEND_DIR/main" && ! -f "$BACKEND_DIR/main.py" ]]; then
  nohup "$BACKEND_DIR/main" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  exit 0
fi

# Prefer a modern Python (>=3.10) for the venv: /usr/bin/python3 on macOS
# is Apple-shipped 3.9, which cannot evaluate `X | Y` type annotations.
pick_python() {
  for candidate in /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  echo "/usr/bin/python3"
}

# A packaged venv is read-only at runtime. Changed/missing dependencies use
# an Application Support venv instead of modifying the signed app bundle.
REQ_HASH="$(shasum -a 256 "$REQ_FILE" | awk '{print $1}')"
if [[ -x "$BUNDLED_VENV_DIR/bin/python" && -f "$BUNDLED_VENV_DIR/.req_hash" && "$(cat "$BUNDLED_VENV_DIR/.req_hash")" == "$REQ_HASH" ]]; then
  VENV_DIR="$BUNDLED_VENV_DIR"
else
  VENV_DIR="$PID_DIR/backend-venv"
fi
REQ_HASH_FILE="$VENV_DIR/.req_hash"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$(pick_python)" -m venv "$VENV_DIR"
fi

# ── Dependency install: skip entirely if requirements.txt hasn't changed ──
if [[ -f "$REQ_FILE" ]]; then
  REQ_HASH="$(shasum -a 256 "$REQ_FILE" | awk '{print $1}')"
  CACHED_HASH=""
  if [[ -f "$REQ_HASH_FILE" ]]; then
    CACHED_HASH="$(cat "$REQ_HASH_FILE" 2>/dev/null || true)"
  fi

  if [[ "$REQ_HASH" != "$CACHED_HASH" ]]; then
    echo "[Backend] requirements.txt changed — running pip install..." >> "$LOG_FILE"
    "$VENV_DIR/bin/python" -m pip install --upgrade pip >> "$PIP_LOG_FILE" 2>&1
    "$VENV_DIR/bin/python" -m pip install -r "$REQ_FILE" >> "$PIP_LOG_FILE" 2>&1
    echo "$REQ_HASH" > "$REQ_HASH_FILE"
    echo "[Backend] pip install complete." >> "$LOG_FILE"
  else
    echo "[Backend] Dependencies unchanged — skipping pip install." >> "$LOG_FILE"
  fi
fi

cd "$BACKEND_DIR"
nohup "$VENV_DIR/bin/python" -m uvicorn voice_auth_service:app --host "$HOST" --port "$PORT" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
