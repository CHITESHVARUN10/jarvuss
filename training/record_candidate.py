#!/usr/bin/env python3
"""Attach measured candidate evidence to an isolated export; never activate it."""
import argparse
import json
from pathlib import Path

from evaluate_generalization import ROOT, sha


def legacy_metrics(report):
    result={}
    for name,suite in report['suites'].items():
        summary=suite['summary'];rows=suite['rows']
        latencies=sorted(r['latency_ms'] for r in rows)
        result[name]=dict(count=summary['count'],exact=summary['exact'],exact_match=summary['exact_match'],
            parse_valid=summary['schema_valid'],correct_above_confidence_threshold=sum(r['exact'] and r['confidence']>=.75 for r in rows),
            p50_ms=suite['p50_ms'],p95_ms=latencies[min(len(latencies)-1,int(.95*len(latencies)))],
            failures=[dict(text=r['text'],expected=r['expected'],predicted=r['predicted']) for r in rows if not r['exact']])
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--run',type=Path,required=True)
    p.add_argument('--baseline',type=Path,required=True);args=p.parse_args()
    run=args.run.resolve()
    if not run.is_relative_to(ROOT/'training/out'):p.error('only isolated training/out runs may be annotated')
    report=json.loads((run/'development.json').read_text());baseline=json.loads(args.baseline.read_text())
    gate_path=run/'checkpoint/generalization-gate.json';gate=json.loads(gate_path.read_text())
    model=run/'onnx';meta_path=model/'model_meta.json';meta=json.loads(meta_path.read_text())
    if any(sha(model/name)!=value for name,value in report['weights'].items()):raise ValueError('evaluation weights do not match export')
    if gate['model_weights']!=report['weights']:raise ValueError('gate refers to different weights')
    candidate=legacy_metrics(report);old=legacy_metrics(baseline)
    legacy=all(candidate[n]['exact_match']>=.9 for n in ('native_search','shuffle','volume','workspace')) and all(candidate[n]['exact']>=old[n]['exact'] for n in ('valid','test','novel'))
    passed=legacy and gate['promotion_passed']
    result=dict(candidate=candidate,baseline=old,promotion_passed=passed,generalization_gate_sha256=sha(gate_path))
    (run/'checkpoint/evaluation.json').write_text(json.dumps(result,indent=2)+'\n')
    meta.update(evaluation=candidate,promotion_passed=passed)
    meta_path.write_text(json.dumps(meta,indent=2)+'\n')
    print('Recorded promotion:',passed,'(active model unchanged)')


if __name__=='__main__':main()
