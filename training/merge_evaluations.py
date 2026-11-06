#!/usr/bin/env python3
"""Reuse immutable predictions only when weights/decoder/schema are identical.

No inference or relabeling. Newly authored development predictions are combined
with historical regression predictions, preserving source hashes explicitly.
"""
import argparse
import json
from pathlib import Path
from evaluate_generalization import annotate_novelty,sha,novelty_paths


def merge(base,additions,reference_paths=None):
    result=json.loads(json.dumps(base))
    for label,report,source_suite in additions:
        for key in ('weights','decoder_sha256','schema_sha256'):
            if report[key]!=base[key]:raise ValueError('cannot reuse predictions with different '+key)
        if label in result['suites']:raise ValueError('duplicate suite '+label)
        result['suites'][label]=report['suites'][source_suite]
        result['files'][label]=report['files'][source_suite]
    result.pop('changes',None)
    return annotate_novelty(result,reference_paths) if reference_paths is not None else annotate_novelty(result)


def main():
    p=argparse.ArgumentParser();p.add_argument('--base',type=Path,required=True)
    p.add_argument('--legacy',type=Path,required=True)
    p.add_argument('--add',nargs=3,action='append',default=[],metavar=('NAME','REPORT','SUITE'))
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--novelty-reference',type=Path,help='frozen common candidate-lineage source manifest')
    args=p.parse_args()
    read=lambda path:json.loads(Path(path).read_text())
    base=read(args.base);legacy=read(args.legacy)
    additions=[('previous_development' if n=='development' else n,legacy,n) for n in legacy['suites']]
    additions += [(name,read(path),suite) for name,path,suite in args.add]
    result=merge(base,additions,novelty_paths(args.novelty_reference) if args.novelty_reference else None)
    paths=[args.base,args.legacy]+[Path(a[1]) for a in args.add]
    result['source_reports']={str(path.resolve()):sha(path) for path in paths}
    result['reuse_note']='Immutable CPU serving predictions reused only for identical weights, decoder and schema; novelty slices recomputed against current corpus. No scores or labels changed.'
    args.output.write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':main()
