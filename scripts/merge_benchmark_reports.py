#!/usr/bin/env python3
"""Merge repeated runtime benchmark launches into one median report."""
from __future__ import annotations

import argparse
import copy
import json
import statistics
from pathlib import Path


def median(values):
    values = [value for value in values if value is not None]
    return statistics.median(values) if values else None


def merge(inputs, label, assets):
    reports = [json.loads(Path(path).read_text()) for path in inputs]
    report = copy.deepcopy(reports[0])
    report["label"] = label
    report["merged"] = True
    report["merged_inputs"] = [str(path) for path in inputs]

    for key in ("rss_idle", "rss_loaded"):
        for field in ("median_bytes", "max_bytes", "footprint_bytes"):
            report[key]["app"][field] = median(
                [item[key]["app"].get(field) for item in reports]
            )

    summary = report["runner"]["summary"]
    for field in ("intent_warm_median_ms", "intent_model_median_ms", "plan_warm_median_ms"):
        summary[field] = median([item["runner"]["summary"].get(field) for item in reports])

    for mode in ("intent", "plan"):
        rows = {}
        for item in reports:
            for row in item["runner"].get(mode, []):
                rows.setdefault(row["command"], []).append(row)
        merged_rows = []
        for command, values in rows.items():
            elapsed = median([value.get("elapsed_ms") for value in values])
            base = copy.deepcopy(values[0])
            base["elapsed_ms"] = elapsed
            base["round"] = -1
            if "model_ms" in base:
                base["model_ms"] = median([value.get("model_ms") for value in values])
            if "steps" in base:
                base["steps"] = median([value.get("steps") for value in values])
            merged_rows.append(base)
        report["runner"][mode] = merged_rows

    if assets:
        source = json.loads(Path(assets).read_text())
        for key in ("whisper", "ollama", "voice"):
            if key in source:
                report[key] = source[key]

    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", nargs="+", required=True)
    parser.add_argument("--assets", help="report supplying whisper/ollama/voice sections")
    parser.add_argument("--label", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    report = merge(args.inputs, args.label, args.assets)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
