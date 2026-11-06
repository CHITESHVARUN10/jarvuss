#!/usr/bin/env python3
"""Seeded, reproducible fresh recombination audit; refuses to overwrite a suite.

These bounded grammars test slot transfer and surface-form consistency, not all
possible speech. Author new grammars periodically and keep real-user review.
"""
import argparse
import json
from pathlib import Path
import random

from evaluation_data import ROOT, heldout_paths, text_key
from generalization_data import digest


def generate(seed, pairs=100):
    rng=random.Random(seed)
    blocked={text_key(json.loads(s)['text']) for p in [*ROOT.glob('dataset/*.jsonl'),*heldout_paths()]
             for s in p.read_text().splitlines() if s.strip()}
    rows=[]; seen=set()
    def i(intent_name,**args):return dict(name=intent_name,args=args)
    adjectives=['cerulean','mossy','tangerine','frosted','sienna','tawny','verdant','carmine','ochre','azure']
    nouns=['sextant','gazette','isthmus','cairn','canopy','foliage','solstice','hearth','quarry','tapestry']
    for idx in range(pairs):
        kind=idx%10; n=rng.randint(1,99)
        slot=rng.choice(adjectives)+' '+rng.choice(nouns)+' '+str(rng.randint(101,999))
        if kind==0: text=f'set volume to {n} percent'; labels=[i('volume.set',level=n)]; family='volume'
        elif kind==1: text=f'lower sound by {n} percent'; labels=[i('volume.down',by=n)]; family='volume'
        elif kind==2: text=f'open {slot} project in VS Code'; labels=[i('project.open')]; family='workspace'
        elif kind==3: text=f'play playlist {slot} without shuffle'; labels=[i('media.shuffle')]; family='shuffle'
        elif kind==4: text=f'play {slot} on Spotify'; labels=[i('media.play_song',title=slot)]; family='media'
        elif kind==5: text=f'search Google for {slot} and the ancient map'; labels=[i('web.search',engine='Google',query=slot+' and the ancient map')]; family='web'
        elif kind==6: text=f'create a folder named {slot}'; labels=[i('folder.create',name=slot)]; family='creation'
        elif kind==7: text=f'find PDFs containing {slot}'; labels=[i('files.search')]; family='native_search'
        elif kind==8: text=f'open {slot} project in Finder then open it in Terminal'; labels=[i('project.open'),i('project.open')]; family='compound'
        else: text=f'open Safari and set volume to {n}'; labels=[i('app.open',name='Safari'),i('volume.set',level=n)]; family='compound'
        variants=[text,'Jarvis, '+text+' please.']
        # Workspace parser does not remove trailing please; prefix variation
        # is sufficient without pretending unsupported text is executable.
        if family in ('workspace','compound') and any(x['name']=='project.open' for x in labels): variants[1]='could you please '+text
        if any(text_key(t) in blocked or text_key(t) in seen for t in variants): continue
        for variant,t in enumerate(variants):
            seen.add(text_key(t))
            rows.append(dict(text=t,intents=labels,family=family,slice='seeded_recombination',
                             template_id=f'challenge:{kind}:{variant}',pair_id=f'{seed}:{idx}'))
    return rows


def main():
    p=argparse.ArgumentParser();p.add_argument('--seed',type=int,required=True)
    p.add_argument('--pairs',type=int,default=100);p.add_argument('--output-dir',type=Path,required=True)
    args=p.parse_args()
    if args.pairs<10: p.error('at least10 pairs are required')
    if args.output_dir.exists(): p.error('choose a fresh directory; audits are immutable')
    rows=generate(args.seed,args.pairs)
    if len(rows)<20:p.error('too few fresh cases remain; choose a new seed or add new grammars')
    args.output_dir.mkdir(parents=True)
    path=args.output_dir/'audit.jsonl'
    path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    (args.output_dir/'manifest.json').write_text(json.dumps(dict(seed=args.seed,requested_pairs=args.pairs,
        rows=len(rows),sha256=digest(path),generator_sha256=digest(Path(__file__)),
        policy='One final evaluation after checkpoint selection; use a fresh seed and new phrasing families for later selection cycles.'),indent=2)+'\n')
    print(f'{len(rows)} fresh challenge rows; {len(rows)//2} paired variations')


if __name__=='__main__': main()
