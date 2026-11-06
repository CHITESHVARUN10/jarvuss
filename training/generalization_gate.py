#!/usr/bin/env python3
"""Strict, artifact-bound release evidence; a gain cannot hide another loss."""
import argparse
import json
from pathlib import Path

from evaluate_generalization import compare, sha


def gate(candidate, baseline, retention, audits):
    checks=[]
    def check(name,passed,detail): checks.append(dict(name=name,passed=bool(passed),detail=detail))
    def matched(a,b):
        return (a['decoder_sha256']==b['decoder_sha256'] and a.get('schema_sha256')==b.get('schema_sha256') and
                a.get('novelty_reference')==b.get('novelty_reference') and
                all(k in b['files'] and v['sha256']==b['files'][k]['sha256'] for k,v in a['files'].items()))
    check('development suite provenance',matched(candidate,baseline) and matched(candidate,retention),'same decoder and frozen suite hashes')
    changes=compare(candidate['suites'],baseline['suites'])
    retained=compare(candidate['suites'],retention['suites'])
    for name,suite in candidate['suites'].items():
        now=suite['summary'];old=baseline['suites'][name]['summary']
        check(name+' no aggregate regression',now['exact']>=old['exact'],f"{now['exact']}/{now['count']} vs {old['exact']}/{old['count']}")
        check(name+' no lost073 cases',not retained[name]['regressed'],retained[name]['regressed'])
        if name in ('native_search','shuffle','volume','workspace','development'):
            check(name+' >=90%',now['exact_match']>=.9,now['exact_match'])
    for name,c,b,r in audits:
        check(name+' weights bound',c['weights']==candidate['weights'],'same quantized candidate weights')
        check(name+' suite provenance',matched(c,b) and matched(c,r),'same decoder and frozen audit hashes')
        suite=c['suites']['audit'];now=suite['summary'];old=b['suites']['audit']['summary']
        check(name+' >=90%',now['exact_match']>=.9,now['exact_match'])
        unfamiliar=suite.get('structure_slices',{}).get('unseen',{})
        prior=b['suites']['audit'].get('structure_slices',{}).get('unseen',{})
        check(name+' unfamiliar structures >=90%',unfamiliar.get('count',0)>0 and unfamiliar.get('exact_match',0)>=.9,
              [unfamiliar.get('exact'),unfamiliar.get('count')])
        check(name+' unfamiliar structures no regression',unfamiliar.get('count',0)==prior.get('count') and unfamiliar.get('exact',-1)>=prior.get('exact',0),
              [unfamiliar.get('exact'),prior.get('exact')])
        check(name+' accepted precision >=baseline',now['accepted_precision']>=old['accepted_precision'],
              [now['accepted_precision'],old['accepted_precision']])
        check(name+' no lost073 cases',not compare(c['suites'],r['suites'])['audit']['regressed'],
              compare(c['suites'],r['suites'])['audit']['regressed'])
        for family,item in suite['families'].items():
            before=b['suites']['audit']['families'][family]
            check(name+'/'+family+' no regression',item['exact']>=before['exact'],[item['exact'],before['exact'],item['count']])
    check('independent final audits present',len(audits)>=2,'authored grammar audit and fresh seeded recombination audit required')
    return dict(promotion_passed=all(c['passed'] for c in checks),checks=checks,
                model_weights=candidate['weights'],legacy_changes=changes,retention_changes=retained)


def main():
    p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
    p.add_argument('--baseline',type=Path,required=True);p.add_argument('--retention',type=Path,required=True)
    p.add_argument('--audit',nargs=4,action='append',default=[],metavar=('NAME','CANDIDATE','BASELINE','RETENTION'))
    p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    read=lambda path:json.loads(Path(path).read_text())
    audits=[(name,read(c),read(b),read(r)) for name,c,b,r in args.audit]
    result=gate(read(args.candidate),read(args.baseline),read(args.retention),audits)
    paths=[args.candidate,args.baseline,args.retention]+[Path(x) for a in args.audit for x in a[1:]]
    result['evidence']={str(path.resolve()):sha(path) for path in paths}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    for c in result['checks']:
        if not c['passed']: print('FAIL:',c['name'],c['detail'])
    return 0 if result['promotion_passed'] else 1


if __name__=='__main__': raise SystemExit(main())
