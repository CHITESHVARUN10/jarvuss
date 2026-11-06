"""Shared held-out discovery and normalization (no ML dependencies)."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text_key(text):
    return re.sub(r'[^\w]+', ' ', text.removeprefix('parse: ').casefold()).strip()


def heldout_paths():
    return sorted({ROOT/'dataset/valid.jsonl', ROOT/'dataset/test.jsonl',
                   *ROOT.glob('training/eval_*.jsonl'),
                   *ROOT.glob('training/benchmarks/**/*.jsonl')})
