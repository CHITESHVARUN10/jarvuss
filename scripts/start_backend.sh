#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$SCRIPT_DIR/../Resources/backend" ]]; then
  BACKEND_DIR="$(cd "$SCRIPT_DIR/../Resources/backend" && pwd)"
else
  BACKEND_DIR="$(cd "$SCRIPT_DIR/../backend" && pwd)"
fi
VENV_DIR="$BACKEND_DIR/venv"
REQ_FILE="$BACKEND_DIR/requirements.txt"
REQ_HASH_FILE="$VENV_DIR/.req_hash"
PID_DIR="$HOME/Library/Application Support/Jarvis"
PID_FILE="$PID_DIR/backend.pid"
LOG_DIR="$PID_DIR/logs"
LOG_FILE="$LOG_DIR/backend.log"
PIP_LOG_FILE="$LOG_DIR/backend-pip.log"
HOST="127.0.0.1"
PORT="8000"

mkdir -p "$PID_DIR" "$LOG_DIR"

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
