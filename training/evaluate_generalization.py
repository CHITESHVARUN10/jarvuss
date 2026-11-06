#!/usr/bin/env python3
"""Serving-decoder evaluation with complete predictions and paired regressions.

Development is reusable for selection. Audit is a separately recorded final
check, never a source for another training correction in the same benchmark.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import random
from pathlib import Path
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from intent_router_model import _OnnxIntentEngine
from post_train import schema_score, load_schema
from leakage_report import signature

LEGACY = dict(native_search=ROOT/'training/eval_native_search.jsonl',valid=ROOT/'dataset/valid.jsonl',
              test=ROOT/'dataset/test.jsonl',novel=ROOT/'training/eval_novel.jsonl',
              shuffle=ROOT/'training/eval_spotify_shuffle.jsonl',volume=ROOT/'training/eval_system_volume.jsonl',
              workspace=ROOT/'training/eval_workspace.jsonl')


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def wilson(correct,count):
    if not count: return [0,1]
    z=1.96; p=correct/count; d=1+z*z/count
    mid=(p+z*z/(2*count))/d
    half=z*math.sqrt(p*(1-p)/count+z*z/(4*count*count))/d
    return [mid-half,mid+half]


def summarize(rows):
    exact=sum(r['exact'] for r in rows); n=len(rows)
    accepted=[r for r in rows if r['confidence']>=0.75 and r['schema_valid']]
    groups=defaultdict(list)
    for r in rows: groups[r['family']].append(r)
    pairs=defaultdict(list)
    for r in rows:
        if r.get('pair_id'): pairs[r['pair_id']].append(r)
    pairs=[v for v in pairs.values() if len(v)>1]
    templates=defaultdict(list)
    for r in rows: templates[r.get('template_id') or r['text']].append(r)
    clusters=[(sum(r['exact'] for r in group),len(group)) for group in templates.values()]
    rng=random.Random(74); bootstrap=[]
    if clusters:
        for _ in range(500):
            sample=rng.choices(clusters,k=len(clusters))
            bootstrap.append(sum(c for c,n in sample)/sum(n for c,n in sample))
        bootstrap.sort()
    return dict(count=n,exact=exact,exact_match=exact/max(1,n),wilson95=wilson(exact,n),
                schema_valid=sum(r['schema_valid'] for r in rows)/max(1,n),
                intent_sequence_exact=sum(r['intent_sequence_exact'] for r in rows)/max(1,n),
                accepted=len(accepted),accepted_wrong=sum(not r['exact'] for r in accepted),
                accepted_precision=sum(r['exact'] for r in accepted)/max(1,len(accepted)),
                macro_family_exact=sum(sum(r['exact'] for r in v)/len(v) for v in groups.values())/max(1,len(groups)),
                paired_groups=len(pairs),paired_all_correct=sum(all(r['exact'] for r in v) for v in pairs),
                template_groups=len(clusters),group_bootstrap95=[bootstrap[12],bootstrap[487]] if bootstrap else [0,1])


def evaluate(model, suites):
    engine=_OnnxIntentEngine(model); schema=load_schema(); report={}
    for name,path in suites.items():
        rows=[]
        for line in path.read_text().splitlines():
            row=json.loads(line); start=time.perf_counter()
            raw,confidence=engine.generate(row['text'])
            latency=(time.perf_counter()-start)*1000
            try: predicted=json.loads(raw)
            except ValueError: predicted=None
            expected=row['intents']
            valid=schema_score(predicted,schema)==1
            names=lambda v:[x.get('name') for x in v] if isinstance(v,list) and all(isinstance(x,dict) for x in v) else None
            rows.append(dict(text=row['text'],expected=expected,predicted=predicted,exact=valid and predicted==expected,
                             schema_valid=valid,intent_sequence_exact=names(predicted)==names(expected),
                             family=row.get('family',expected[0]['name']),slice=row.get('slice','paraphrase'),
                             template_id=row.get('template_id'),pair_id=row.get('pair_id'),
                             confidence=confidence,latency_ms=latency))
        by_family=defaultdict(list); by_slice=defaultdict(list)
        for r in rows:
            by_family[r['family']].append(r); by_slice[r['slice']].append(r)
        report[name]=dict(summary=summarize(rows),families={k:summarize(v) for k,v in by_family.items()},
                          slices={k:summarize(v) for k,v in by_slice.items()},rows=rows,
                          p50_ms=statistics.median(r['latency_ms'] for r in rows))
        print(f'{model.parent.name}/{model.name} {name}: {report[name]["summary"]["exact"]}/{len(rows)}',flush=True)
    return report


def compare(candidate,reference):
    changes={}
    for name,suite in candidate.items():
        if name not in reference: continue
        old={r['text']:r for r in reference[name]['rows']}
        gains=[]; losses=[]
        for r in suite['rows']:
            before=old[r['text']]
            if r['exact'] and not before['exact']: gains.append(r['text'])
            if before['exact'] and not r['exact']: losses.append(r['text'])
        changes[name]=dict(improved=gains,regressed=losses)
    return changes


def novelty_paths(manifest):
    reference=json.loads(manifest.read_text())
    paths=[]
    for rel,expected in reference['files'].items():
        path=(ROOT/rel).resolve()
        if not path.is_relative_to(ROOT/'dataset') or sha(path)!=expected:
            raise ValueError('frozen exposure reference changed: '+rel)
        paths.append(path)
    return paths


def annotate_novelty(report,reference_paths=None):
    """Conservative common exposure reference, including all repository shards.

    This annotation changes no prediction or gold label. It does not claim to
    detect semantic memorization or prove genuine out-of-distribution behavior.
    """
    paths=sorted(reference_paths if reference_paths is not None else ROOT.glob('dataset/train*.jsonl'))
    templates={signature(json.loads(s)) for p in paths for s in p.read_text().splitlines() if s.strip()}
    report['novelty_reference']={str(p.relative_to(ROOT)):sha(p) for p in paths}
    for suite in report['suites'].values():
        for row in suite['rows']:
            row['unseen_structure']=signature(dict(text=row['text'],intents=row['expected'])) not in templates
        suite['structure_slices']={
            name:summarize([r for r in suite['rows'] if r['unseen_structure']==flag])
            for name,flag in [('unseen',True),('familiar',False)]}
    return report


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--split',choices=['development','audit'],default='development')
    p.add_argument('--benchmark',type=Path,default=ROOT/'training/benchmarks/generalization-v2')
    p.add_argument('--without-legacy',action='store_true')
    p.add_argument('--novelty-reference',type=Path,help='frozen candidate-lineage source manifest for a stable common structural reference')
    p.add_argument('--regression-suite',nargs=2,action='append',default=[],metavar=('NAME','PATH'),
                   help='include a consumed benchmark as a clearly named regression suite')
    p.add_argument('--reference',type=Path,help='previous full serving evaluation JSON, same suite hashes required')
    args=p.parse_args()
    args.benchmark=args.benchmark.resolve()
    suites={} if args.without_legacy else dict(LEGACY)
    suites[args.split]=args.benchmark/(args.split+'.jsonl')
    for name,path in args.regression_suite:
        if name in suites:p.error('duplicate suite name: '+name)
        suites[name]=Path(path).resolve()
    files={name:dict(path=str(path.relative_to(ROOT)),sha256=sha(path)) for name,path in suites.items()}
    if args.split=='audit':
        receipt=args.output.with_suffix('.audit-access.json')
        if args.output.exists() or receipt.exists():
            p.error('audit outputs are immutable; choose a new output path for an explicitly recorded repeat')
        receipt.parent.mkdir(parents=True,exist_ok=True)
        receipt.write_text(json.dumps(dict(started_utc=datetime.now(timezone.utc).isoformat(),model=str(args.model),files=files),indent=2)+'\n')
    report=dict(model=str(args.model.resolve()),created_utc=datetime.now(timezone.utc).isoformat(),files=files,
                decoder_sha256=sha(ROOT/'backend/intent_router_model.py'),
                schema_sha256=sha(ROOT/'training/intent_schema.json'),
                weights={p.name:sha(p) for p in args.model.glob('*quantized.onnx')},
                suites=evaluate(args.model,suites))
    annotate_novelty(report,novelty_paths(args.novelty_reference) if args.novelty_reference else None)
    if any(sha(suites[name])!=item['sha256'] for name,item in files.items()):
        raise ValueError('a benchmark changed during evaluation')
    if any(sha(args.model/name)!=value for name,value in report['weights'].items()):
        raise ValueError('model weights changed during evaluation')
    if args.reference:
        reference=json.loads(args.reference.read_text())
        for name in suites:
            if reference['files'][name]['sha256']!=files[name]['sha256']: raise ValueError('benchmark changed: '+name)
        report['changes']=compare(report['suites'],reference['suites'])
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    return 0


if __name__=='__main__': raise SystemExit(main())
