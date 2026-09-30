#!/usr/bin/env python3
"""Prepare seq2seq training data from dataset/*.jsonl.

Reads the hand-authored dataset shards, validates every line against
intent_schema.json, canonicalizes targets (fixed key order, compact JSON),
and writes HuggingFace-format files to training/data/.

Usage:
    python prepare_data.py            # validate + write training/data/*
    python prepare_data.py --check    # validate only, no files written
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET_DIR = os.path.join(ROOT, "dataset")
SCHEMA_PATH = os.path.join(ROOT, "training", "intent_schema.json")
OUT_DIR = os.path.join(ROOT, "training", "data")
NOVEL_PATH = os.path.join(ROOT, "training", "eval_novel.jsonl")

INPUT_PREFIX = "parse: "
DEV_FRACTION = 0.05
SEED = 13


def load_schema() -> dict:
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return json.load(f)["intents"]


def canonicalize(intents: list, schema: dict) -> tuple[str, list[str]]:
    """Return (canonical_json, errors). Rebuilds each intent with the schema's
    arg order and compact separators so targets are deterministic."""
    errors: list[str] = []
    out = []
    for i, intent in enumerate(intents):
        name = intent.get("name")
        args = intent.get("args", {})
        if name not in schema:
            errors.append(f"[{i}] unknown intent '{name}'")
            continue
        spec = schema[name]
        if not isinstance(args, dict):
            errors.append(f"[{i}] {name}: args is not an object")
            continue
        unknown = set(args) - set(spec["args"])
        missing = set(spec["args"]) - set(args)
        if unknown:
            errors.append(f"[{i}] {name}: unexpected args {sorted(unknown)}")
        if missing:
            errors.append(f"[{i}] {name}: missing args {sorted(missing)}")
        ordered = {}
        for arg in spec["args"]:
            if arg not in args:
                continue
            value = args[arg]
            expected = spec["types"][arg]
            if expected == "int" and not isinstance(value, int):
                errors.append(f"[{i}] {name}.{arg}: expected int, got {type(value).__name__}")
            if expected == "str" and not isinstance(value, str):
                errors.append(f"[{i}] {name}.{arg}: expected str, got {type(value).__name__}")
            ordered[arg] = value
        out.append({"name": name, "args": ordered})
    return json.dumps(out, separators=(",", ":"), ensure_ascii=False), errors


def read_lines(path: str) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append((lineno, json.loads(line)))
            except json.JSONDecodeError as e:
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {e}")
    return rows


def process_file(path: str, schema: dict) -> tuple[list[dict], int]:
    """Validate + canonicalize one JSONL file. Returns (pairs, error_count)."""
    pairs = []
    errors = 0
    for lineno, obj in read_lines(path):
        text = obj.get("text")
        intents = obj.get("intents")
        if not isinstance(text, str) or not text.strip():
            print(f"{path}:{lineno}: missing/empty text", file=sys.stderr)
            errors += 1
            continue
        if not isinstance(intents, list) or not intents:
            print(f"{path}:{lineno}: missing/empty intents", file=sys.stderr)
            errors += 1
            continue
        target, errs = canonicalize(intents, schema)
        for e in errs:
            print(f"{path}:{lineno}: {e}", file=sys.stderr)
        errors += len(errs)
        if errs:
            continue
        pairs.append(
            {
                "input_text": INPUT_PREFIX + text.strip(),
                "target_text": target,
            }
        )
    return pairs, errors


def train_shards() -> list[str]:
    shards = sorted(glob.glob(os.path.join(DATASET_DIR, "train*.jsonl")))
    return shards


def write_jsonl(path: str, rows: list[dict]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="validate only, write nothing")
    args = ap.parse_args()

    schema = load_schema()
    shards = train_shards()
    if not shards:
        print("no train*.jsonl shards found", file=sys.stderr)
        return 1

    all_pairs: list[dict] = []
    total_errors = 0
    for shard in shards:
        pairs, errs = process_file(shard, schema)
        all_pairs.extend(pairs)
        total_errors += errs

    valid, verrs = process_file(os.path.join(DATASET_DIR, "valid.jsonl"), schema)
    test, terrs = process_file(os.path.join(DATASET_DIR, "test.jsonl"), schema)
    total_errors += verrs + terrs

    novel: list[dict] = []
    if os.path.exists(NOVEL_PATH):
        novel, nerrs = process_file(NOVEL_PATH, schema)
        total_errors += nerrs

    print(f"train shards : {len(shards)} files, {len(all_pairs)} examples")
    print(f"valid        : {len(valid)} examples")
    print(f"test         : {len(test)} examples")
    print(f"novel (eval) : {len(novel)} examples")
    if total_errors:
        print(f"VALIDATION ERRORS: {total_errors}")
        return 1

    if args.check:
        print("check passed")
        return 0

    rng = random.Random(SEED)
    rng.shuffle(all_pairs)
    dev_n = max(1, int(len(all_pairs) * DEV_FRACTION))
    dev = all_pairs[:dev_n]
    train = all_pairs[dev_n:]

    write_jsonl(os.path.join(OUT_DIR, "train.jsonl"), train)
    write_jsonl(os.path.join(OUT_DIR, "dev.jsonl"), dev)
    write_jsonl(os.path.join(OUT_DIR, "valid.jsonl"), valid)
    write_jsonl(os.path.join(OUT_DIR, "test.jsonl"), test)
    if novel:
        write_jsonl(os.path.join(OUT_DIR, "novel.jsonl"), novel)

    print(f"wrote {OUT_DIR}: train={len(train)} dev={len(dev)} "
          f"valid={len(valid)} test={len(test)} novel={len(novel)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
