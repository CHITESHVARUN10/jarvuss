#!/usr/bin/env python3
"""Offline differential check against the unchanged Python intent engine.

Run with a development Python containing backend/requirements.txt. No service,
credentials, model training or actions are used. Output records synthetic/local
test utterances; use an ignored output directory for private corpora.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", type=Path, default=ROOT / "backend/models/intent-t5-small")
    p.add_argument("--probe", type=Path, default=ROOT / "rust-core/target/release/intent-probe")
    p.add_argument("--corpus", action="append", type=Path, default=[])
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    sys.path.insert(0, str(ROOT / "backend"))
    from intent_router_model import _OnnxIntentEngine, INPUT_PREFIX, InputTooLong
    import numpy as np
    import onnxruntime as ort
    import sentencepiece as sp

    library = next((Path(ort.__file__).parent / "capi").glob("libonnxruntime.*.dylib"))
    texts = ["pause", "open Brave and Notes", "open my portfolio project in VS Code",
             "open a new tab in Chrome", "set volume to twenty five percent",
             "shuffle my liked songs", "play song Blinding Lights", "find files containing Jarvis now",
             "open https://example.com in Brave", 'search for {"hello": "world"}',
             "open café", "検索のテスト", "open naïve résumé project in Finder",
             "open ChatGPT\u200b", "a " * 180]
    for path in args.corpus:
        if path.suffix == ".jsonl":
            rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        else:
            rows = json.loads(path.read_text())
            if isinstance(rows, dict):
                rows = rows.get("cases", rows.get("results", []))
        for row in rows:
            text = row if isinstance(row, str) else row.get("input", row.get("text", row.get("command")))
            if not text and isinstance(row, dict) and "input_text" in row:
                text = row["input_text"].removeprefix(INPUT_PREFIX)
            if text:
                texts.append(text)
    texts = list(dict.fromkeys(texts))
    started = time.perf_counter()
    engine = _OnnxIntentEngine(args.model)
    python_load = (time.perf_counter() - started) * 1000
    original_decoder = engine.dec

    class Recorder:
        def __init__(self):
            self.ids = []
        def run(self, names, feed):
            out = original_decoder.run(names, feed)
            logits = out[engine.dec_output_names.index("logits")][0, -1]
            next_id = int(logits.argmax())
            if next_id != 1:
                self.ids.append(next_id)
            return out

    recorder = Recorder()
    engine.dec = recorder
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # File-backed stderr avoids pipe deadlock and keeps load diagnostics intact.
    with args.output.with_suffix(".native.log").open("w+") as native_log:
        process = subprocess.Popen([str(args.probe), str(args.model), str(library)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=native_log, text=True, bufsize=1)
        records = []
        try:
            for i, text in enumerate(texts):
                recorder.ids = []
                start = time.perf_counter()
                try:
                    ids = engine.encode(INPUT_PREFIX + text)
                    raw, confidence = engine.generate(text)
                    reference = dict(raw=raw, confidence=confidence, input_ids=ids,
                                     generated_ids=recorder.ids.copy())
                except InputTooLong:
                    reference = {"error": "input_too_long"}
                elapsed = (time.perf_counter() - start) * 1000
                process.stdin.write(json.dumps(text) + "\n")
                process.stdin.flush()
                response = process.stdout.readline()
                if not response:
                    raise RuntimeError("Native probe terminated; see .native.log")
                native = json.loads(response)
                current = native.get("generation", {"error": native.get("error")})
                fields = ["error"] if "error" in reference else ["input_ids", "generated_ids", "raw"]
                mismatches = [f for f in fields if reference.get(f) != current.get(f)]
                confidence_delta = None
                if "confidence" in reference and "confidence" in current:
                    confidence_delta = abs(reference["confidence"] - current["confidence"])
                    if confidence_delta > 1e-8:
                        mismatches.append("confidence")
                    if round(reference["confidence"], 4) != round(current["confidence"], 4):
                        mismatches.append("rounded_confidence")
                    if (round(reference["confidence"], 4) >= 0.75) != (round(current["confidence"], 4) >= 0.75):
                        mismatches.append("admission")
                records.append(dict(text=text, reference=reference, native=current,
                                    python_ms=elapsed, native_ms=native.get("elapsed_ms"),
                                    confidence_delta=confidence_delta, mismatches=mismatches))
                if (i + 1) % 25 == 0:
                    print(f"Compared {i + 1}/{len(texts)}", flush=True)
            process.stdin.close()
            if process.wait(timeout=30) != 0:
                raise RuntimeError("Native probe failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    failures = [r for r in records if r["mismatches"]]
    valid = [r for r in records if "error" not in r["reference"]]
    files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
             for p in args.model.iterdir() if p.is_file()}
    report = dict(cases=len(records), failed=len(failures), python_load_ms=python_load,
                  python_median_ms=statistics.median(r["python_ms"] for r in valid),
                  native_median_ms=statistics.median(r["native_ms"] for r in valid),
                  max_confidence_delta=max((r["confidence_delta"] or 0 for r in records), default=0),
                  ort_version=ort.__version__, sentencepiece_version=sp.__version__,
                  model_files=files, python_decoder_sha256=hashlib.sha256((ROOT / "backend/intent_router_model.py").read_bytes()).hexdigest(),
                  corpus_paths=[str(p) for p in args.corpus], records=records,
                  caveat="Sequential direct-engine comparison; not full voice-command latency or a controlled speed ratio.")
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("records", "model_files")}, indent=2))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
