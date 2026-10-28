#!/bin/zsh
# Post-train on MPS, and automatically retry on CPU if the MPS allocator
# blows up (it fragments badly on long runs and aborts mid-epoch).
#
#   ./run_post_train.sh            # normal run, detached by the caller
#   EPOCHS=1 BATCH=2 ./run_post_train.sh   # quick run
#
# Everything is appended to post_train.log.
set -u

cd "$(dirname "$0")" || exit 1

PY="${JARVIS_TRAINING_PYTHON:-.venv/bin/python}"
EPOCHS="${EPOCHS:-3}"
BATCH="${BATCH:-4}"     # halved from 8 to cut peak activation memory
ACCUM="${ACCUM:-8}"     # keeping the effective batch at 32

"$PY" prepare_data.py || exit $?

run_attempt() {
    local device="$1"
    echo "=== attempt: device=$device batch=$BATCH accum=$ACCUM epochs=$EPOCHS ==="
    if [[ "$device" == "mps" ]]; then
        $PY post_train.py --train --device mps \
                --epochs "$EPOCHS" --batch "$BATCH" --accum "$ACCUM" \
                --init-from "${INIT_FROM:-out/post}" --output-dir "${OUTPUT_DIR:-out/native-search}"
    else
        $PY post_train.py --train --device cpu \
            --epochs "$EPOCHS" --batch "$BATCH" --accum "$ACCUM" \
                --init-from "${INIT_FROM:-out/post}" --output-dir "${OUTPUT_DIR:-out/native-search}"
    fi
}

run_attempt mps
attempt_exit=$?

if [[ $attempt_exit -eq 0 ]]; then
    echo "=== done (mps) ==="
    exit 0
fi

echo "=== MPS attempt failed (exit $attempt_exit) — falling back to CPU ==="
run_attempt cpu
attempt_exit=$?

if [[ $attempt_exit -eq 0 ]]; then
    echo "=== done (cpu) ==="
else
    echo "=== both attempts failed (exit $attempt_exit) ==="
fi
exit $attempt_exit
