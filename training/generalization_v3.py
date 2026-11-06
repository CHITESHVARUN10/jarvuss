#!/usr/bin/env python3
"""Fresh grammatical audit edition after consuming v2; no model outputs read."""
import json
from collections import Counter
from pathlib import Path
import re
from evaluation_data import ROOT,heldout_paths,text_key
from generalization_data import digest

DEST=ROOT/'training/benchmarks/generalization-v3'


def words(n):
    small='zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen'.split()
    tens=['','','twenty','thirty','forty','fifty','sixty','seventy','eighty','ninety']
    return small[n] if n<20 else tens[n//10]+(' '+small[n%10] if n%10 else '')


def generate():
    blocked={text_key(json.loads(s)['text']) for p in [*ROOT.glob('dataset/*.jsonl'),*heldout_paths()]
             if not p.is_relative_to(DEST) for s in p.read_text().splitlines() if s.strip()}
    output={}
    for split in ('development','audit'):
        t=0 if split=='development' else 1
        names=[['pale juniper','dapper sketch','monarch cove','scarlet atoll','fabled chronicle'],
               ['flaxen summit','reed constellation','sable orchestra','bracken haven','almond theorem']][t]
        old=['violet sundial','willow sonata','zinc lighthouse','opal caravan','saffron voyage'] if t==0 else ['cypress prism','topaz orchard','velvet estuary','wren almanac','jade monsoon']
        rename=dict(zip(old,names));rows=[]
        def add(text,intents,family,slice='new_paraphrase',template='main',resolved=None):
            key=text_key(text)
            if key in blocked:return
            blocked.add(key)
            row=dict(text=text,intents=intents,family=family,slice=slice,template_id=f'v3:{split}:{family}:{template}')
            if resolved is not None:row['resolved_args']=resolved
            rows.append(row)
        def i(name,**args):return dict(name=name,args=args)
        source=ROOT/f'training/benchmarks/generalization-v2/{split}.jsonl'
        for row in map(json.loads,source.read_text().splitlines()):
            labels=json.loads(json.dumps(row['intents']));family=row['family']
            for label in labels:
                for k,v in label['args'].items():
                    if type(v) is int:label['args'][k]=(v*3+7)%99+1
                    elif isinstance(v,str):
                        for before,after in rename.items():v=v.replace(before,after)
                        label['args'][k]=v
            first=labels[0];name=first['name'];args=first['args'];text=None;resolved=None
            if len(labels)>1:
                if name=='project.open':
                    slot=names[len(rows)%len(names)]
                    text=[f'open my {slot} project on Finder then open it in VS Code',f'please open project {slot} in Terminal and then open it with Finder'][t]
                elif name.startswith('app.new_'):
                    text=['make a new window in Brave and create a new tab in Chrome','create a new tab in Brave and make a new window in Chrome'][t]
                    labels=[i('app.new_window' if t==0 else 'app.new_tab'),i('app.new_tab' if t==0 else 'app.new_window')]
                else:
                    n=labels[1]['args'].get('level',labels[1]['args'].get('by'))
                    labels=[dict(name='app.open',args=dict(name='Safari')),i('volume.down',by=n)]
                    text=[f'launch Safari and decrease system audio by {words(n)} percent',f'start Safari then lower speaker sound by {n} percentage points'][t]
            elif name.startswith('volume.') and args:
                n=args.get('level',args.get('by'));amount=words(n) if row.get('slice')=='spoken_number' else str(n)
                op=name.split('.')[1]
                patterns={'set':[f'put the speaker sound at {amount} percent please',f'can you adjust audio to {amount} percent'],
                          'up':[f'turn speaker sound up by {amount} percent please',f'could you boost my volume by {amount} percentage points'],
                          'down':[f'turn speaker sound down by {amount} percent please',f'could you reduce my volume by {amount} percentage points']}
                text=patterns[op][t]
            elif name.startswith('display.'):
                attr,op=name.split('.')[1].rsplit('_',1);n=args.get('level',args.get('by'))
                verb={'set':'set','up':'increase','down':'decrease'}[op];prep='to' if op=='set' else 'by'
                text=[f'I need you to {verb} display {attr} {prep} {n} percent',f'would you {verb} my screen {attr} {prep} {n} percent'][t]
            elif name=='web.search':
                text=[f'use {args["engine"]} to look up {args["query"]}',f'on {args["engine"]}, find information about {args["query"]}'][t]
            elif name in ('file.create','folder.create'):
                typ=name.split('.')[0];slot=args["name"]
                text=[f'make me a {typ} with the name {slot}',f'I need a new {typ} called {slot}'][t]
            elif name=='media.play_song':text=[f'start playing the song {args["title"]}',f'let me hear the song {args["title"]}'][t]
            elif name=='media.play_playlist':text=[f'start playing my playlist {args["name"]}',f'let me hear my {args["name"]} playlist'][t]
            elif name=='project.open':
                r=row['resolved_args'][0];slot=r['project']
                for before,after in rename.items():slot=slot.replace(before,after)
                app={'finder':'Finder','vscode':'VS Code','terminal':'Terminal'}[r['app']]
                text=[f'can you open project {slot} on {app}',f'please open project {slot} from lab in {app}'][t]
                resolved=[dict(operation='openProject',app=r['app'],project=slot,root='lab' if t else '')]
            elif name in ('app.new_window','app.new_tab'):
                r=row['resolved_args'][0];app={'chrome':'Chrome','brave':'Brave Browser','vscode':'VS Code'}[r['app']]
                kind='terminal tab' if r['operation']=='newTerminalTab' else 'window' if name.endswith('window') else 'tab'
                text=[f'please make one new {kind} of {app}',f'can you please create a new {app} {kind}' if kind!='terminal tab' else f'can you create one new terminal tab for {app}'][t]
                resolved=[r]
            elif name=='files.search':
                slot=next((after for before,after in rename.items() if before in row['text']),names[0])
                content='containing' in row['text']
                text=([f'could you locate files titled {slot}',f'please locate the {slot} document'][t] if not content else
                      [f'locate PDFs with text {slot}',f'could you find PDF files that mention {slot}'][t])
                resolved=dict(query=slot,mode='content' if content else 'name',kind='pdf' if content else 'any',scope='',date='any',min_bytes=0,max_bytes=0)
            elif name=='media.shuffle':
                slot=next((after for before,after in rename.items() if before in row['text']),None)
                off='in order' in row['text'] or 'off' in row['text']
                if slot:text=[f'play the {slot} playlist with shuffle '+('off' if off else 'on'),f'shuffle playlist {slot}' if not off else f'play my {slot} playlist sequentially'][t]
                else:text=[f'okay Jarvis, switch shuffle mode '+('off' if off else 'on'),f'can you please turn the shuffle '+('off' if off else 'on')][t]
            elif name in ('app.open','app.close'):
                verb='start' if name=='app.open' else 'quit'
                text=[f'can you {verb} {args["name"]} now',f'I want you to {verb} {args["name"]} please'][t]
            elif name=='folder.open':text=[f'bring up the {args["name"]} directory',f'show my {args["name"]} folder now'][t]
            elif name=='file.open_latest':text=[f'fetch and open the newest file under {args["folder"]}',f'I need the most recent file in {args["folder"]} opened'][t]
            elif name=='files.query':
                folder=args["folder"];op=args["op"]
                text=([f'give me the file count in {folder}',f'report how many files {folder} contains'][t] if op=='count' else
                      [f'which file takes the most space in {folder}',f'identify the biggest file under {folder}'][t])
            elif name=='install.preview':text=[f'can you add {args["package"]} through brew',f'please use homebrew to install {args["package"]}'][t]
            elif name=='url.open':text=[f'browse to {args["url"]}',f'load the page at {args["url"]}'][t]
            elif name=='url.open_in':text=[f'browse to {args["url"]} with {args["browser"]}',f'load {args["url"]} using the {args["browser"]} browser'][t]
            elif name.startswith('info.'):
                subject={'battery':'battery charge','bluetooth':'Bluetooth connection status','wifi':'wireless connection status','volume':'system volume','brightness':'display brightness','contrast':'screen contrast','time':'local time','date':'calendar date'}[name.split('.')[1]]
                text=[f'give me a reading of the {subject}',f'I would like to know the current {subject}'][t]
            elif name=='settings.open':
                pane=re.search(r'(Bluetooth|Wi-Fi|Sound|Privacy|Display)',row['text'])[0]
                text=[f'okay Jarvis, show the {pane} preferences',f'could you please open the {pane} preferences'][t]
            elif name=='files.result':
                ordinal=re.search(r'(first|second|third|fourth|fifth)',row['text'])[0]
                verb=next(v for v in ('preview','reveal','open') if v in row['text'])
                text=[f'would you please {verb} result {ordinal}',f'okay Jarvis, {verb} the {ordinal} item'][t]
            elif name=='ai.query':
                topic=['how browser extensions interact','why headphones have impedance','how folder permissions work','what sample rates measure','why indexes speed up file searches'][len(rows)%5]
                text=[f'I need an explanation of {topic}',f'please help me understand {topic} in simple terms'][t]
                labels=[i('ai.query',text=text)]
            else:
                phrase={'media.play':'continue playback','media.pause':'halt music playback','media.next':'move on to the next song',
                        'media.previous':'return to the preceding song','media.play_liked':'start up my saved tracks',
                        'volume.mute':'mute system sound','volume.unmute':'unmute system sound'}[name]
                text=[f'would you please {phrase}',f'okay Jarvis, please {phrase}'][t]
            add(text,labels,family,row.get('slice','new_paraphrase'),name,resolved)
        for app in ('Chrome','Brave','Spotify','Terminal'):
            for text in ([f'do not launch {app}',f'leave {app} running instead of closing it',f'what does "close {app}" refer to'] if t==0 else
                         [f'never launch {app}',f'keep {app} open; do not shut it down',f'describe the meaning of "open {app}"']):
                add(text,[i('ai.query',text=text)],'boundary','negation_or_reference','negative')
        for slot in (["Lily's Index",'Résumé Desk','Cobalt_Lab-82','Aurora Chapter 418'] if t==0 else
                     ["Cloud's Ledger",'Crème Transit','Opal_Desk-91','Atlas Chapter 627']):
            add(f'please make a file called "{slot}"',[dict(name='file.create',args=dict(name=slot))],'creation','quoted_literal','quote')
            add(f'open "{slot}" project in Finder',[i('project.open')],'workspace','quoted_literal','quote_project')
        output[split]=rows
    return output


if __name__=='__main__':
    if DEST.exists():raise SystemExit('refusing to overwrite immutable benchmark edition')
    DEST.mkdir(parents=True);rows=generate()
    for split,data in rows.items():(DEST/(split+'.jsonl')).write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in data))
    (DEST/'manifest.json').write_text(json.dumps(dict(version=3,policy='New audit grammar and slots after consuming v2; no outputs consulted for this edition.',generator_sha256=digest(Path(__file__)),files={s:dict(sha256=digest(DEST/(s+'.jsonl')),count=len(r),families=dict(Counter(x['family'] for x in r))) for s,r in rows.items()}),indent=2)+'\n')
    print({s:len(r) for s,r in rows.items()})
