#!/usr/bin/env python3
"""Report exact and structural overlap, without rewriting labels or training."""
import argparse
import json
from pathlib import Path
import re

from evaluation_data import text_key


def signature(row):
    text=row['text'].casefold()
    # Replace exact free-form slots. Do not replace the whole ai.query text.
    slots=[]
    for item in row['intents']:
        if item['name']=='ai.query':continue
        for k,v in item['args'].items():
            if isinstance(v,str) and len(v)>2 and k in ('query','title','url','package','name'):
                slots.append(v.casefold())
    for slot in sorted(slots,key=len,reverse=True):text=text.replace(slot,' SLOT ')
    text=re.sub(r'\bproject from .+? (in|on|with)\b',r'project from ROOT \1',text)
    text=re.sub(r'(open (?:my |the )?)(.+?)( project)',r'\1SLOT\3',text)
    text=re.sub(r'(containing|named|called) .+?(?= please[.!?]?$|$)',r'\1 SLOT',text)
    text=re.sub(r'\b(?:\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|first|second|third|fourth|fifth|sixth|seventh)\b',' NUM ',text)
    text=re.sub(r'\b(?:visual studio code|vs code|brave browser|brave|google chrome|chrome|safari|finder|terminal|spotify|notes)\b',' APP ',text)
    text=re.sub(r'\b(?:downloads|documents|desktop|pictures|movies|music)\b',' FOLDER ',text)
    text=re.sub(r'^(?:(?:hey )?jarvis[, ]+|(?:can|could|would) you |please )+','',text)
    text=re.sub(r'(?:[,.!? ]+(?:please|for me|now|right now))?[.!?]*$','',text)
    return text_key(text)


def analyze(training,evaluation):
    exact={text_key(r['text']) for r in training}
    templates={signature(r) for r in training}
    return dict(count=len(evaluation),exact_overlap=[r['text'] for r in evaluation if text_key(r['text']) in exact],
                structural_overlap=[r['text'] for r in evaluation if signature(r) in templates],
                caveat='Heuristic delexicalization; absence of a match is not proof of semantic novelty. Politeness-only variation is not counted as new structure.')


def main():
    p=argparse.ArgumentParser();p.add_argument('--train',nargs='+',type=Path,required=True)
    p.add_argument('--eval',nargs='+',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();read=lambda p:[json.loads(s) for s in p.read_text().splitlines() if s.strip()]
    train=[r for path in args.train for r in read(path)]
    report={str(path):analyze(train,read(path)) for path in args.eval}
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    for k,v in report.items(): print(k,v['count'],'exact',len(v['exact_overlap']),'structural',len(v['structural_overlap']))
    return int(any(v['exact_overlap'] for v in report.values()))


if __name__=='__main__':raise SystemExit(main())
