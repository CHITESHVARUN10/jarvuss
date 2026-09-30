#!/usr/bin/env python3
"""Evaluate the trained intent model: exact-match, parse-validity, action P/R/F1, latency.

Usage:
    python evaluate.py                          # torch model at training/out/best
    python evaluate.py --onnx backend/models/intent-t5-small   # int8 ONNX model
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import time

import torch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "training", "data")
OUT_DIR = os.path.join(ROOT, "training", "out")
SCHEMA_PATH = os.path.join(ROOT, "training", "intent_schema.json")
MAX_SOURCE_LEN = 128
MAX_TARGET_LEN = 448
INPUT_PREFIX = "parse: "


def load_jsonl(path: str) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def load_schema_names() -> set:
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return set(json.load(f)["intents"].keys())


def parse_actions(text: str, valid_names: set):
    """Return canonical list of (name, args-json) or None if invalid."""
    try:
        obj = json.loads(text)
    except Exception:
        return None
    if not isinstance(obj, list) or not obj:
        return None
    out = []
    for item in obj:
        if not isinstance(item, dict) or item.get("name") not in valid_names:
            return None
        args = item.get("args", {})
        if not isinstance(args, dict):
            return None
        out.append((item["name"], json.dumps(args, sort_keys=True, ensure_ascii=False)))
    return out


def multiset_scores(pred_actions, gold_actions):
    """Per-example TP/FP/FN over the multiset of (name, args)."""
    pred = list(pred_actions)
    gold = list(gold_actions)
    tp = 0
    for action in list(pred):
        if action in gold:
            gold.remove(action)
            pred.remove(action)
            tp += 1
    return tp, len(pred), len(gold)


def evaluate_predictions(rows: list[dict], predict_fn, valid_names: set) -> dict:
    exact = 0
    exact_string = 0
    parse_ok = 0
    tp = fp = fn = 0
    for row in rows:
        pred_text = predict_fn(row["input_text"])
        gold_text = row["target_text"]
        exact_string += int(pred_text.strip() == gold_text.strip())
        pred_actions = parse_actions(pred_text, valid_names)
        gold_actions = parse_actions(gold_text, valid_names) or []
        # Semantic exact-match: intents + args identical (whitespace-insensitive;
        # added {/} tokens decode with a cosmetic space).
        if pred_actions is not None:
            exact += int(pred_actions == gold_actions)
            parse_ok += 1
            t, f, n = multiset_scores(pred_actions, gold_actions)
            tp += t
            fp += f
            fn += n
        else:
            fn += len(gold_actions)
    n = max(1, len(rows))
    precision = tp / max(1, tp + fp)
    recall = tp / max(1, tp + fn)
    f1 = 2 * precision * recall / max(1e-9, precision + recall)
    return {
        "n": len(rows),
        "exact_match": exact / n,
        "exact_string": exact_string / n,
        "parse_valid": parse_ok / n,
        "action_precision": precision,
        "action_recall": recall,
        "action_f1": f1,
    }


def make_torch_predictor(model_dir: str):
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForSeq2SeqLM.from_pretrained(model_dir)
    model.eval()

    def predict(input_text: str) -> str:
        batch = tokenizer([input_text], return_tensors="pt", max_length=MAX_SOURCE_LEN, truncation=True)
        with torch.no_grad():
            out = model.generate(**batch, max_length=MAX_TARGET_LEN, num_beams=1, do_sample=False)
        return tokenizer.batch_decode(out, skip_special_tokens=True)[0]

    return predict


def make_onnx_predictor(model_dir: str):
    from optimum.onnxruntime import ORTModelForSeq2SeqLM
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    kwargs = {}
    quantized = os.path.join(model_dir, "encoder_model_quantized.onnx")
    if os.path.exists(quantized):
        kwargs = {
            "encoder_file_name": "encoder_model_quantized.onnx",
            "decoder_file_name": "decoder_model_merged_quantized.onnx",
        }
    try:
        model = ORTModelForSeq2SeqLM.from_pretrained(model_dir, **kwargs)
    except Exception:
        model = ORTModelForSeq2SeqLM.from_pretrained(model_dir)

    def predict(input_text: str) -> str:
        batch = tokenizer([input_text], return_tensors="pt", max_length=MAX_SOURCE_LEN, truncation=True)
        out = model.generate(**batch, max_length=MAX_TARGET_LEN, num_beams=1, do_sample=False)
        return tokenizer.batch_decode(out, skip_special_tokens=True)[0]

    return predict


def latency_bench(predict_fn, rows: list[dict], warmup: int = 5) -> dict:
    sample = [r["input_text"] for r in rows[:40]]
    for text in sample[:warmup]:
        predict_fn(text)
    times = []
    for text in sample:
        t0 = time.perf_counter()
        predict_fn(text)
        times.append((time.perf_counter() - t0) * 1000.0)
    times.sort()
    return {
        "n": len(times),
        "p50_ms": statistics.median(times),
        "p95_ms": times[min(len(times) - 1, int(len(times) * 0.95))],
        "mean_ms": statistics.fmean(times),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(OUT_DIR, "best"))
    ap.add_argument("--onnx", action="store_true", help="load via optimum ONNX runtime")
    ap.add_argument("--json-out", default=os.path.join(OUT_DIR, "metrics.json"))
    args = ap.parse_args()

    valid_names = load_schema_names()
    predict = make_onnx_predictor(args.model) if args.onnx else make_torch_predictor(args.model)

    results = {}
    for split in ["valid", "test", "novel"]:
        path = os.path.join(DATA_DIR, f"{split}.jsonl")
        if not os.path.exists(path):
            continue
        rows = load_jsonl(path)
        results[split] = evaluate_predictions(rows, predict, valid_names)
        print(f"{split:6s}: exact={results[split]['exact_match']:.3f} "
              f"parse_valid={results[split]['parse_valid']:.3f} "
              f"action_f1={results[split]['action_f1']:.3f}")

    if os.path.exists(os.path.join(DATA_DIR, "dev.jsonl")):
        dev_rows = load_jsonl(os.path.join(DATA_DIR, "dev.jsonl"))
        results["latency_dev"] = latency_bench(predict, dev_rows)
        print(f"latency: p50={results['latency_dev']['p50_ms']:.1f}ms "
              f"p95={results['latency_dev']['p95_ms']:.1f}ms")

    os.makedirs(os.path.dirname(args.json_out), exist_ok=True)
    with open(args.json_out, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)
    print(f"wrote {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
