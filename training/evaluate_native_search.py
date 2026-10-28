#!/usr/bin/env python3
"""Evaluate staged int8 weights with the actual backend decoder.

No services are started. Evaluation uses authored held-out phrases only.
    python training/evaluate_native_search.py --candidate training/out/native-search-onnx
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from intent_router_model import _OnnxIntentEngine


def evaluate(model: Path) -> dict:
    engine = _OnnxIntentEngine(model)
    files = {
        "native_search": ROOT / "training/eval_native_search.jsonl",
        "valid": ROOT / "dataset/valid.jsonl",
        "test": ROOT / "dataset/test.jsonl",
        "novel": ROOT / "training/eval_novel.jsonl",
    }
    report = {}
    for name, path in files.items():
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        exact = valid = accepted = 0
        latencies, failures = [], []
        for row in rows:
            started = time.perf_counter()
            raw, confidence = engine.generate(row["text"])
            latencies.append((time.perf_counter() - started) * 1000)
            try:
                predicted = json.loads(raw)
                valid += isinstance(predicted, list) and bool(predicted)
            except ValueError:
                predicted = None
            matches = predicted == row["intents"]
            exact += matches
            accepted += matches and confidence >= 0.75
            if not matches:
                failures.append({"text": row["text"], "expected": row["intents"], "predicted": predicted})
        report[name] = {
            "count": len(rows), "exact": exact, "exact_match": exact / len(rows),
            "parse_valid": valid / len(rows), "correct_above_confidence_threshold": accepted,
            "p50_ms": statistics.median(latencies),
            "p95_ms": sorted(latencies)[min(len(latencies) - 1, int(0.95 * len(latencies)))],
            "failures": failures,
        }
        print(f"{model.name} {name}: {exact}/{len(rows)} exact, {accepted} correct above confidence threshold", flush=True)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, default=ROOT / "training/out/native-search-onnx")
    parser.add_argument("--baseline", type=Path, default=ROOT / "backend/models/intent-t5-small")
    parser.add_argument("--output", type=Path, default=ROOT / "training/out/native-search/evaluation.json")
    args = parser.parse_args()
    report = {"candidate": evaluate(args.candidate), "baseline": evaluate(args.baseline)}
    # Require a strong new-feature result and no aggregate regression on the
    # unchanged independent general-language sets before promoting weights.
    native = report["candidate"]["native_search"]
    candidate_general = sum(report["candidate"][name]["exact"] for name in ("valid", "test", "novel"))
    baseline_general = sum(report["baseline"][name]["exact"] for name in ("valid", "test", "novel"))
    report["promotion_passed"] = native["exact_match"] >= 0.9 and candidate_general >= baseline_general
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Promotion gate: {report['promotion_passed']} (general {candidate_general} vs baseline {baseline_general})")
    return 0 if report["promotion_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
