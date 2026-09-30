#!/usr/bin/env python3
"""Export the trained intent model to int8 ONNX for the backend.

Steps:
  1. optimum-cli export onnx (text2text-generation) -> backend/models/intent-t5-small/
  2. dynamic int8 quantization of encoder + merged decoder via onnxruntime
  3. write a small model_meta.json (base model, schema version)

Usage:
    python export_onnx.py                     # from training/out/best
    python export_onnx.py --model <dir>
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "training", "out")
DEST = os.path.join(ROOT, "backend", "models", "intent-t5-small")


def run(cmd: list[str]) -> None:
    print("$", " ".join(cmd))
    subprocess.run(cmd, check=True)


def quantize(path: str) -> None:
    from onnxruntime.quantization import QuantType, quantize_dynamic

    quantized_path = path.replace(".onnx", "_quantized.onnx")
    quantize_dynamic(path, quantized_path, weight_type=QuantType.QInt8)
    size_mb = os.path.getsize(quantized_path) / 1e6
    print(f"quantized {os.path.basename(path)} -> {os.path.basename(quantized_path)} ({size_mb:.1f} MB)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(OUT_DIR, "best"))
    ap.add_argument("--dest", default=DEST)
    args = ap.parse_args()

    if not os.path.isdir(args.model):
        print(f"model dir not found: {args.model}", file=sys.stderr)
        return 1

    tmp = os.path.join(OUT_DIR, "onnx_export")
    if os.path.isdir(tmp):
        shutil.rmtree(tmp)

    from optimum.exporters.onnx import main_export

    main_export(
        model_name_or_path=args.model,
        output=tmp,
        task="text2text-generation-with-past",
    )

    if os.path.isdir(args.dest):
        shutil.rmtree(args.dest)
    os.makedirs(args.dest, exist_ok=True)

    for name in os.listdir(tmp):
        src = os.path.join(tmp, name)
        dst = os.path.join(args.dest, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)

    for fname in ["encoder_model.onnx", "decoder_model_merged.onnx"]:
        path = os.path.join(args.dest, fname)
        if os.path.exists(path):
            quantize(path)
        else:
            print(f"warning: {fname} not found in export", file=sys.stderr)

    # Drop fp32 onnx files: only the quantized pair is served (optimum loads
    # *_quantized.onnx when the plain files are absent). The no-past decoder and
    # the with-past shard only exist to build the merged quantized decoder.
    merged_q = os.path.join(args.dest, "decoder_model_merged_quantized.onnx")
    for fname in [
        "encoder_model.onnx",
        "decoder_model_merged.onnx",
        "decoder_model.onnx",
        "decoder_with_past_model.onnx",
    ]:
        path = os.path.join(args.dest, fname)
        if not os.path.exists(path):
            continue
        quantized_counterpart = (
            os.path.join(args.dest, "encoder_model_quantized.onnx")
            if fname == "encoder_model.onnx"
            else merged_q
        )
        if os.path.exists(quantized_counterpart):
            os.remove(path)
            print(f"removed fp32 {fname}")

    meta = {"base_model": "t5-small", "task": "intent-parse", "quantized": True}
    with open(os.path.join(args.dest, "model_meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    total = sum(
        os.path.getsize(os.path.join(args.dest, f))
        for f in os.listdir(args.dest)
        if os.path.isfile(os.path.join(args.dest, f))
    )
    print(f"exported to {args.dest} ({total / 1e6:.1f} MB of top-level files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
