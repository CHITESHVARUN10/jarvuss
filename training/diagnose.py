#!/usr/bin/env python3
"""Diagnose exact-match failures: show input / gold / pred / confidence.

Confidence = geometric mean of chosen-token probabilities (same as the
backend reports), so we can calibrate IntentModelRouter.confidenceThreshold.
"""
import json
import math
import os

import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "training", "data")
MODEL_DIR = os.path.join(ROOT, "training", "out", "best")

tok = AutoTokenizer.from_pretrained(MODEL_DIR)
model = AutoModelForSeq2SeqLM.from_pretrained(MODEL_DIR)
model.eval()


def predict(text: str):
    batch = tok([text], return_tensors="pt", max_length=128, truncation=True)
    with torch.no_grad():
        out = model.generate(**batch, max_length=448, num_beams=1, do_sample=False,
                             output_scores=True, return_dict_in_generate=True)
    raw = tok.batch_decode(out.sequences, skip_special_tokens=True)[0].strip()
    logprobs = []
    for step, scores in enumerate(out.scores):
        tid = int(out.sequences[0, step + 1])
        logprobs.append(float(torch.log_softmax(scores[0], dim=-1)[tid]))
    conf = math.exp(sum(logprobs) / len(logprobs)) if logprobs else 0.0
    return raw, conf


def canonical(text: str) -> str:
    try:
        return json.dumps(json.loads(text), sort_keys=True, separators=(",", ":"))
    except Exception:
        return text


fail = 0
total = 0
conf_ok = []
conf_bad = []
for split in ["valid", "test", "novel"]:
    path = os.path.join(DATA_DIR, f"{split}.jsonl")
    if not os.path.exists(path):
        continue
    print(f"\n===== {split} =====")
    for line in open(path):
        row = json.loads(line)
        pred, conf = predict(row["input_text"])
        total += 1
        if canonical(pred) == canonical(row["target_text"]):
            conf_ok.append(conf)
            continue
        fail += 1
        conf_bad.append(conf)
        print(f"IN   : {row['input_text']}")
        print(f"GOLD : {row['target_text']}")
        print(f"PRED : {pred}")
        print(f"CONF : {conf:.3f}")
        print("---")

print(f"\ntotal={total} exact={total-fail} fail={fail}")
if conf_ok:
    print(f"correct: min={min(conf_ok):.3f} p05={sorted(conf_ok)[max(0, len(conf_ok)//20)]:.3f}")
if conf_bad:
    print(f"wrong  : max={max(conf_bad):.3f} p50={sorted(conf_bad)[len(conf_bad)//2]:.3f}")
