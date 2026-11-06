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
import hashlib
from collections import defaultdict
from evaluation_data import heldout_paths, text_key

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET_DIR = os.path.join(ROOT, "dataset")
SCHEMA_PATH = os.path.join(ROOT, "training", "intent_schema.json")
OUT_DIR = os.path.join(ROOT, "training", "data")
NOVEL_PATH = os.path.join(ROOT, "training", "eval_novel.jsonl")
NATIVE_EVAL_PATH = os.path.join(ROOT, "training", "eval_native_search.jsonl")
SHUFFLE_EVAL_PATH = os.path.join(ROOT, "training", "eval_spotify_shuffle.jsonl")
VOLUME_EVAL_PATH = os.path.join(ROOT, "training", "eval_system_volume.jsonl")

WORKSPACE_EVAL_PATH = os.path.join(ROOT, "training", "eval_workspace.jsonl")

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
            if expected == "int" and type(value) is not int:
                errors.append(f"[{i}] {name}.{arg}: expected int, got {type(value).__name__}")
            if expected == "str" and not isinstance(value, str):
                errors.append(f"[{i}] {name}.{arg}: expected str, got {type(value).__name__}")
            if arg in spec.get('enums',{}) and value not in spec['enums'][arg]:
                errors.append(f"[{i}] {name}.{arg}: unsupported value {value!r}")
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
    ap.add_argument("--shards", nargs="+", help="explicit dataset shard paths; omit to prepare all shards")
    ap.add_argument("--output-dir", default=OUT_DIR, help="isolated prepared-data directory")
    ap.add_argument("--development", help="explicit versioned development.jsonl; never an audit file")
    ap.add_argument("--cap-per-intent-sequence", type=int, default=0,
                    help="deterministic cap per ordered intent-name sequence; zero keeps all selected rows")
    args = ap.parse_args()
    if args.cap_per_intent_sequence < 0:
        ap.error('--cap-per-intent-sequence must be nonnegative')
    development = os.path.realpath(args.development) if args.development else None
    benchmark_root = os.path.realpath(os.path.join(ROOT, 'training', 'benchmarks')) + os.sep
    if development and (not development.startswith(benchmark_root) or os.path.basename(development) != 'development.jsonl' or not os.path.isfile(development)):
        ap.error('--development must be a versioned benchmarks/.../development.jsonl')

    schema = load_schema()
    shards = sorted(set(os.path.abspath(path) for path in args.shards)) if args.shards else train_shards()
    for path in shards:
        if not os.path.isfile(path) or os.path.dirname(os.path.realpath(path)) != os.path.realpath(DATASET_DIR) or not os.path.basename(path).startswith("train") or not path.endswith(".jsonl"):
            ap.error(f"not a dataset training shard: {path}")
    output_dir = os.path.abspath(args.output_dir)
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

    native_eval, nerrs = process_file(NATIVE_EVAL_PATH, schema) if os.path.exists(NATIVE_EVAL_PATH) else ([], 0)
    total_errors += nerrs
    shuffle_eval, serrs = process_file(SHUFFLE_EVAL_PATH, schema) if os.path.exists(SHUFFLE_EVAL_PATH) else ([], 0)
    total_errors += serrs
    volume_eval, aerrs = process_file(VOLUME_EVAL_PATH, schema) if os.path.exists(VOLUME_EVAL_PATH) else ([], 0)
    total_errors += aerrs

    workspace_eval, werrs = process_file(WORKSPACE_EVAL_PATH, schema) if os.path.exists(WORKSPACE_EVAL_PATH) else ([], 0)
    total_errors += werrs

    print(f"train shards : {len(shards)} files, {len(all_pairs)} examples")
    print(f"valid        : {len(valid)} examples")
    print(f"test         : {len(test)} examples")
    print(f"novel (eval) : {len(novel)} examples")
    if total_errors:
        print(f"VALIDATION ERRORS: {total_errors}")
        return 1

    # Group identical utterances before splitting. Conflicting labels (notably
    # old generated extension filters) are not trustworthy training targets.
    grouped = defaultdict(dict)
    for pair in all_pairs:
        key = text_key(pair["input_text"])
        grouped[key][pair["target_text"]] = pair
    heldout = {text_key(obj['text']) for path in heldout_paths() for _, obj in read_lines(str(path))}
    conflicts = sum(len(values) > 1 for values in grouped.values())
    all_pairs = [next(iter(values.values())) for key, values in grouped.items()
                 if len(values) == 1 and key not in heldout]
    print(f"deduplicated : {len(all_pairs)} unambiguous examples; excluded {conflicts} conflicting utterances")

    if args.check:
        print("check passed")
        return 0

    rng = random.Random(SEED)
    rng.shuffle(all_pairs)
    uncapped = len(all_pairs)
    if args.cap_per_intent_sequence:
        counts = defaultdict(int)
        selected = []
        for row in all_pairs:
            bucket = tuple(i['name'] for i in json.loads(row['target_text']))
            if counts[bucket] < args.cap_per_intent_sequence:
                selected.append(row)
                counts[bucket] += 1
        all_pairs = selected
        print(f'balanced cap : {len(all_pairs)} of {uncapped} selected rows')
    if development:
        dev, dev_errors = process_file(development, schema)
        if dev_errors:
            return 1
        train = all_pairs
    else:
        dev_n = max(1, int(len(all_pairs) * DEV_FRACTION))
        dev = all_pairs[:dev_n]
        train = all_pairs[dev_n:]

    write_jsonl(os.path.join(output_dir, "train.jsonl"), train)
    write_jsonl(os.path.join(output_dir, "dev.jsonl"), dev)
    write_jsonl(os.path.join(output_dir, "valid.jsonl"), valid)
    write_jsonl(os.path.join(output_dir, "test.jsonl"), test)
    if novel:
        write_jsonl(os.path.join(output_dir, "novel.jsonl"), novel)
    if native_eval:
        write_jsonl(os.path.join(output_dir, "native_search_eval.jsonl"), native_eval)
    if shuffle_eval:
        write_jsonl(os.path.join(output_dir, "spotify_shuffle_eval.jsonl"), shuffle_eval)

    if volume_eval:
        write_jsonl(os.path.join(output_dir, "system_volume_eval.jsonl"), volume_eval)

    if workspace_eval:
        write_jsonl(os.path.join(output_dir, "workspace_eval.jsonl"), workspace_eval)

    def digest(path):
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    manifest = {
        "schema_sha256": digest(SCHEMA_PATH),
        "shards": [{"file": os.path.relpath(path, ROOT), "sha256": digest(path)} for path in shards],
        "prepared": {"train": len(train), "dev": len(dev), "excluded_conflicts": conflicts},
        "eval_only": [{"file": os.path.relpath(path, ROOT), "sha256": digest(path)} for path in heldout_paths() if os.path.exists(path)],
        "development": os.path.relpath(development, ROOT) if development else 'random-five-percent',
        "intent_sequence_cap": args.cap_per_intent_sequence,
        "rows_before_cap": uncapped,
    }
    with open(os.path.join(output_dir, "dataset_manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)

    print(f"wrote {output_dir}: train={len(train)} dev={len(dev)} "
          f"valid={len(valid)} test={len(test)} novel={len(novel)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
