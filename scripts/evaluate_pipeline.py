#!/usr/bin/env python3
"""Offline end-to-end evaluation. No model calls, audio collection or training.

Rows are human-labelled records containing expected_transcript/transcript,
expected_actions/actions and optionally effect_verified, duration_ms, family,
engine and run. Audio and transcripts remain local. Use identical fixture IDs
when comparing recognizers; model-only and effect scores stay separate.
"""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import unicodedata


def words(text):
    text = unicodedata.normalize('NFC', text).casefold().replace('’', "'")
    return ''.join(c if c.isalnum() or c in "'’" else ' ' for c in text).split()


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        row = [i]
        for j, right in enumerate(b, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j-1] + (left != right)))
        previous = row
    return previous[-1]


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(len(values)*p)-1)]


def summarize(rows):
    speech = [r for r in rows if 'expected_transcript' in r and 'transcript' in r]
    plans = [r for r in rows if 'expected_actions' in r and 'actions' in r]
    effects = [r for r in rows if isinstance(r.get('effect_verified'), bool)]
    latencies = [float(r['duration_ms']) for r in rows if isinstance(r.get('duration_ms'), (float, int)) and not isinstance(r['duration_ms'], bool) and math.isfinite(r['duration_ms']) and r['duration_ms'] >= 0]
    reference_words = sum(len(words(r['expected_transcript'])) for r in speech)
    errors = sum(edit_distance(words(r['expected_transcript']), words(r['transcript'])) for r in speech)
    return dict(count=len(rows), speech_cases=len(speech), reference_words=reference_words,
                word_errors=errors, wer=errors/reference_words if reference_words else None,
                plan_cases=len(plans), exact_plans=sum(r['actions']==r['expected_actions'] for r in plans),
                effect_cases=len(effects), verified_effects=sum(r['effect_verified'] for r in effects),
                p50_ms=percentile(latencies, .5), p95_ms=percentile(latencies, .95))


def evaluate(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[(row.get('engine', 'unspecified'), row.get('family', 'unspecified'))].append(row)
    return dict(summary=summarize(rows), slices=[dict(engine=k[0], family=k[1], **summarize(v)) for k,v in sorted(groups.items())])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('records', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args=parser.parse_args()
    rows=[json.loads(line) for line in args.records.read_text().splitlines() if line.strip()]
    ids=[(r.get('engine'), r.get('run'), r['id']) for r in rows]
    if len(ids)!=len(set(ids)): parser.error('duplicate fixture IDs within the same engine/run')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(evaluate(rows),indent=2)+'\n')


if __name__=='__main__': main()
