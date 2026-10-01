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

PY=".venv/bin/python"
EPOCHS="${EPOCHS:-3}"
BATCH="${BATCH:-4}"     # halved from 8 to cut peak activation memory
ACCUM="${ACCUM:-8}"     # keeping the effective batch at 32

run_attempt() {
    local device="$1"
    echo "=== attempt: device=$device batch=$BATCH accum=$ACCUM epochs=$EPOCHS ==="
    if [[ "$device" == "mps" ]]; then
        PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 \
        PYTORCH_MPS_LOW_WATERMARK_RATIO=0.0 \
            $PY post_train.py --train --device mps \
                --epochs "$EPOCHS" --batch "$BATCH" --accum "$ACCUM" \
                --init-from out/best
    else
        $PY post_train.py --train --device cpu \
            --epochs "$EPOCHS" --batch "$BATCH" --accum "$ACCUM" \
            --init-from out/best
    fi
}

run_attempt mps
status=$?

if [[ $status -eq 0 ]]; then
    echo "=== done (mps) ==="
    exit 0
fi

echo "=== MPS attempt failed (exit $status) — falling back to CPU ==="
rm -rf out/post
run_attempt cpu
status=$?

if [[ $status -eq 0 ]]; then
    echo "=== done (cpu) ==="
else
    echo "=== both attempts failed (exit $status) ==="
fi
exit $status
