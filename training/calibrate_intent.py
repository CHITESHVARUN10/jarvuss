#!/usr/bin/env python3
"""Inspect development-only confidence risk/coverage. Never changes serving policy.

The mean token probability is a ranking score, not a calibrated correctness
probability. Threshold suggestions require adequate accepted samples and an
upper Wilson bound below the requested error budget. Audit data is refused.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path


def wilson_upper(errors, n):
    if not n: return 1.0
    z=1.959963984540054; p=errors/n
    return (p+z*z/(2*n)+z*math.sqrt(p*(1-p)/n+z*z/(4*n*n)))/(1+z*z/n)


def calibrate(rows, max_error=.05, min_accepted=50):
    curves=[]
    for threshold in [i/100 for i in range(50,100)]:
        accepted=[r for r in rows if r.get('schema_valid') is True and isinstance(r.get('confidence'),(float,int)) and not isinstance(r['confidence'],bool) and math.isfinite(r['confidence']) and r['confidence'] >= threshold]
        errors=sum(r.get('exact') is not True for r in accepted)
        curves.append(dict(threshold=threshold,accepted=len(accepted),wrong=errors,coverage=len(accepted)/max(1,len(rows)),error_upper95=wilson_upper(errors,len(accepted))))
    eligible=[r for r in curves if r['accepted']>=min_accepted and r['error_upper95']<=max_error]
    return dict(count=len(rows),suggested_threshold=eligible[0]['threshold'] if eligible else None,curve=curves)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('report',type=Path);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--max-error',type=float,default=.05);p.add_argument('--min-accepted',type=int,default=50)
    a=p.parse_args()
    if not 0<a.max_error<1 or a.min_accepted<1:p.error('invalid calibration limits')
    report=json.loads(a.report.read_text())
    development=report.get('suites',{}).get('development')
    if development is None:p.error('a development suite is required; audit and regression suites are not calibration inputs')
    path=report.get('files',{}).get('development',{}).get('path','')
    if 'audit' in path.lower():p.error('audit files cannot be used for threshold calibration')
    rows=development['rows'];families=defaultdict(list)
    for row in rows:families[row['family']].append(row)
    out=dict(input_sha256=hashlib.sha256(a.report.read_bytes()).hexdigest(),weights=report.get('weights'),serving_policy_changed=False,
             overall=calibrate(rows,a.max_error,a.min_accepted),families={k:calibrate(v,a.max_error,a.min_accepted) for k,v in sorted(families.items())})
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n')


if __name__=='__main__':main()
