#!/usr/bin/env python3
"""Versioned synthetic curriculum with disjoint train/development/audit grammars.

This is authored coverage, not a claim of natural-language representativeness.
Audit rows must not be consulted to choose a checkpoint or next experiment.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import re

ROOT = Path(__file__).resolve().parents[1]
SHARD = ROOT / 'dataset/train-074-generalization.jsonl'
BENCH = ROOT / 'training/benchmarks/generalization-v2'


def key(text):
    return re.sub(r'[^\w]+', ' ', text.casefold()).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate():
    blocked = {key(json.loads(line)['text']) for path in
               [*ROOT.glob('dataset/*.jsonl'), *ROOT.glob('training/eval_*.jsonl')]
               if path != SHARD for line in path.read_text().splitlines() if line.strip()}
    result = {s: [] for s in ('train', 'development', 'audit')}
    seen = set(blocked)
    def intent(intent_name, **args): return {'name': intent_name, 'args': args}
    def add(split, family, template, text, labels, **metadata):
        if family in ('volume','workspace','settings','results'):
            text = re.sub(r' (?:now|for me)([.!?]?)$',r'\1',text)
        k = key(text)
        if k in seen: return
        seen.add(k)
        result[split].append(dict(text=text, intents=labels if isinstance(labels, list) else [labels],
                                  family=family, template_id=f'{split}:{family}:{template}', **metadata))

    units = ['zero','one','two','three','four','five','six','seven','eight','nine',
             'ten','eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen','eighteen','nineteen']
    tens = ['','','twenty','thirty','forty','fifty','sixty','seventy','eighty','ninety']
    def words(n):
        return 'one hundred' if n == 100 else units[n] if n < 20 else tens[n//10] + (' '+units[n%10] if n%10 else '')

    pools = {
        'train': ['amber ledger','birch observatory','copper journal','delta orchard','elm archive',
                  'fern workshop','granite voyage','hazel notebook','indigo meadow','juniper clock',
                  'kelp horizon','linen compass','marble lantern','nectar gallery','ochre valley',
                  'pebble compass','quartz garden','raven calendar','silver harbor','timber atlas'],
        'development': ['violet sundial','willow sonata','zinc lighthouse','opal caravan','saffron voyage'],
        'audit': ['cypress prism','topaz orchard','velvet estuary','wren almanac','jade monsoon'],
    }
    number_sets = {'train':[n for n in range(1,101) if n not in (8,19,26,31,48,57,64,73,86,95)],
                   'development':[8,26,48,64,86], 'audit':[19,31,57,73,95]}
    for split, names in pools.items():
        t = {'train':0,'development':1,'audit':2}[split]
        # Held-out templates and slot values; exact integer arithmetic is scored.
        for n in number_sets[split]:
            for spoken in (False, True):
                value = words(n) if spoken else str(n)
                for op in ('set','up','down'):
                    phrases = {
                        'set': [f'please adjust speaker volume to {value} percent now',
                                f'could you put computer volume at {value} percent for me',
                                f'Jarvis, change output volume to {value} percent please.'],
                        'up': [f'please turn output volume up by {value} percent now',
                               f'could you increase speaker sound by {value} percentage points',
                               f'Jarvis, raise computer volume by {value} percent please.'],
                        'down':[f'please turn output volume down by {value} percent now',
                                f'could you decrease speaker sound by {value} percentage points',
                                f'Jarvis, lower computer volume by {value} percent please.'],
                    }
                    add(split,'volume',op+str(spoken),phrases[op][t],
                        intent('volume.'+op,**{('level' if op=='set' else 'by'):n}),
                        slice='spoken_number' if spoken else 'digit_number', pair_id=f'{split}:volume:{op}:{n}')
            for attr in ('brightness','contrast'):
                for op in ('set','up','down'):
                    verb={'set':'set','up':'increase','down':'decrease'}[op]
                    prep='to' if op=='set' else 'by'
                    text=[f'please {verb} display {attr} {prep} {n} percent now',
                          f'could you {verb} screen {attr} {prep} {n} percent for me',
                          f'Jarvis, {verb} the display {attr} {prep} {n} percent please.'][t]
                    add(split,'display',attr+op,text,intent('display.'+attr+'_'+op,**{('level' if op=='set' else 'by'):n}))
        for item in names:
            for engine in ('Google','YouTube','Reddit','Bing'):
                query=item+' restoration guide'
                text=[f'please look for {query} on {engine} now',
                      f'can you search {engine} for {query} for me',
                      f'on {engine} search for {query} please'][t]
                add(split,'web','engine',text,intent('web.search',engine=engine,query=query),slice='unseen_slot')
            for typ in ('file','folder'):
                text=[f'create a {typ} named {item} please now',f'could you make a new {typ} called {item} for me',
                      f'Jarvis, create a new {typ} with the name {item}.'][t]
                add(split,'creation',typ,text,intent(typ+'.create',name=item),slice='unseen_slot')
            for kind in ('song','playlist'):
                text=([f'please play the song {item} now',f'could you put on the song {item} for me',
                       f'I want to listen to the song {item}'][t] if kind=='song' else
                      [f'please start my {item} playlist now',f'could you play the playlist named {item} for me',
                       f'I want to hear my {item} playlist'][t])
                add(split,'media',kind,text,intent('media.play_'+kind,**{('title' if kind=='song' else 'name'):item}),slice='unseen_slot')
            for app in ('Finder','Visual Studio Code','Terminal'):
                text=[f'please open the {item} project in {app}',
                      f'could you open my {item} project with {app}',
                      f'Jarvis, open {item} project from sandbox in {app}.'][t]
                add(split,'workspace','project',text,intent('project.open'),slice='unseen_slot',
                    resolved_args=[dict(operation='openProject',app={'Finder':'finder','Visual Studio Code':'vscode','Terminal':'terminal'}[app],project=item,root='sandbox' if t==2 else '')])
            for enabled in (True,False):
                suffix='in random order' if enabled else 'in order'
                text=[f'please play playlist named {item} {suffix} now',
                      f'could you play my {item} playlist {suffix} please',
                      f'Jarvis, play playlist called {item} {suffix}.'][t]
                # "now" is not a supported trailing filler for native shuffle.
                if split=='train': text=text.removesuffix(' now')
                add(split,'shuffle','playlist'+str(enabled),text,intent('media.shuffle'),slice='unseen_slot')
            for mode in ('name','content'):
                text=([f'please find the {item} document',f'could you find files named {item} please',
                       f'Jarvis, search for files called {item}.'][t] if mode=='name' else
                      [f'please find PDFs containing {item}',f'could you find documents containing {item} please',
                       f'Jarvis, find text files containing {item}.'][t])
                add(split,'native_search',mode,text,intent('files.search'),slice='unseen_slot')
            # Minimal pairs discourage projecting the word "project" into music.
            add(split,'boundary','song_project',[f'please play the song {item} project',
                f'play {item} project on Spotify please',f'put on the song {item} project for me'][t],
                intent('media.play_song',title=item+' project'),slice='boundary')
            add(split,'compound','project_followup',[
                f'open {item} project in Finder and open it in VS Code',
                f'could you open {item} project in Terminal and then open it in Finder',
                f'Jarvis, open {item} project in VS Code then open it in Terminal.'][t],
                [intent('project.open'),intent('project.open')],slice='composition')
            add(split,'compound','web_and_literal',[
                f'please search Google for {item} and the silver moon',
                f'search YouTube for {item} and the quiet ocean please',
                f'look up {item} and the hidden river on Bing'][t],
                intent('web.search',engine=['Google','YouTube','Bing'][t],query=item+[' and the silver moon',' and the quiet ocean',' and the hidden river'][t]),slice='literal_conjunction')
        for app, canonical in [('Chrome','Google Chrome'),('Brave','Brave Browser'),('VS Code','Visual Studio Code'),
                               ('Safari','Safari'),('Spotify','Spotify'),('Notes','Notes'),('Terminal','Terminal'),('Finder','Finder')]:
            for op in ('open','close'):
                text=[f'please {op} the {app} application now',f'could you {op} {app} for me please',
                      f'Jarvis, {op} the app {app}.'][t]
                add(split,'apps',op,text,intent('app.'+op,name=canonical))
        for app in ('Chrome','Brave Browser','Visual Studio Code'):
            for kind in ('window','tab'):
                for variant in range(4 if split=='train' else 2):
                    templates={
                        'train':[f'please open one new {kind} for {app}',f'create one new {kind} in {app}',
                                 f'Jarvis open a new {kind} on {app}',f'please open one new {app} {kind}'],
                        'development':[f'could you make a new {kind} in {app}',f'can you create one new {app} {kind}'],
                        'audit':[f'Jarvis, create a new {kind} for {app}.',f'please make one new {kind} of {app}'],
                    }
                    add(split,'workspace',kind+str(variant),templates[split][variant],intent('app.new_'+kind),
                        resolved_args=[dict(operation='newWindow' if kind=='window' else 'newTab',app={'Chrome':'chrome','Brave Browser':'brave','Visual Studio Code':'vscode'}[app],project='',root='')])
        add(split,'workspace','terminal_tab',['please create one new terminal tab in VS Code',
            'could you make a new terminal tab for Visual Studio Code',
            'Jarvis, create one new terminal tab on VS Code.'][t],intent('app.new_tab'),
            resolved_args=[dict(operation='newTerminalTab',app='vscode',project='',root='')])
        for folder in ('downloads','documents','desktop','pictures','movies','music'):
            add(split,'folders','open',[f'please open my {folder} folder now',f'could you show the {folder} directory for me',
                f'Jarvis, take me to my {folder} folder.'][t],intent('folder.open',name=folder))
            add(split,'folders','latest',[f'please open the newest file from my {folder} folder',f'could you open the latest file in {folder} please',
                f'Jarvis, open my most recent file in {folder}.'][t],intent('file.open_latest',folder=folder))
            for op,verb in [('largest','largest'),('smallest','smallest'),('count','number of')]:
                text=[f'please show the {verb} files in {folder}',f'could you find the {verb} files in {folder} for me',
                      f'Jarvis, show me the {verb} files in {folder}.'][t]
                if op=='count': text=[f'please count files in {folder} now',f'could you tell me how many files are in {folder} please',f'Jarvis, count all files in {folder}.'][t]
                if op=='smallest':
                    add(split,'boundary','unsupported_smallest',text,intent('ai.query',text=text),slice='unsupported_operation')
                else:
                    add(split,'files_query',op,text,intent('files.query',op=op,folder=folder,ext=''))
        for package in ('jq','tree','ripgrep','bat','fzf','tmux','fd','pandoc'):
            add(split,'install','brew',[f'please install {package} with brew now',f'could you preview installing {package} using homebrew',
                f'Jarvis, install {package} via homebrew please.'][t],intent('install.preview',package=package,source='homebrew'))
        for host in ('example.org','example.net','example.com'):
            url='https://'+host+'/guide'
            add(split,'urls','open',[f'please open {url} now',f'could you visit {url} for me',f'Jarvis, go to {url} please.'][t],intent('url.open',url=url))
            add(split,'urls','browser',[f'please open {url} in Chrome now',f'could you open {url} using Brave please',f'Jarvis, visit {url} in Safari.'][t],intent('url.open_in',url=url,browser=['Google Chrome','Brave Browser','Safari'][t]))
        for short,name in [('time','info.time'),('date','info.date'),('volume','info.volume'),('brightness','info.brightness'),
                           ('contrast','info.contrast'),('battery level','info.battery'),('wifi status','info.wifi'),('bluetooth status','info.bluetooth')]:
            add(split,'info',name,[f'please tell me the current {short} now',f'could you report the {short} for me',f'Jarvis, check the current {short} please.'][t],intent(name))
        for phrase,name in [('resume my music','media.play'),('pause playback','media.pause'),('skip this track','media.next'),
                            ('go back to the previous song','media.previous'),('play my liked songs','media.play_liked'),
                            ('mute output audio','volume.mute'),('unmute output audio','volume.unmute')]:
            add(split,'transport',name,[f'please {phrase} right now',f'could you {phrase} for me please',f'Jarvis, {phrase} please.'][t],intent(name))
        for phrase in ['what is an output audio buffer','explain microphone polar patterns','how does a new browser tab work',
                       'what does a coding project contain','why do sound cards have input gain','explain playlist sequencing',
                       'mute the microphone','turn on the camera','increase microphone input gain','explain window managers']:
            text=[phrase+' please explain', 'can you explain this: '+phrase, 'Jarvis, '+phrase+' for me'][t]
            # Unsupported actions remain fallback queries, preserving full text.
            add(split,'boundary','ai',text,intent('ai.query',text=text),slice='boundary')
        for pane in ('Bluetooth','Wi-Fi','Sound','Privacy','Display'):
            add(split,'settings','pane',[f'please open the {pane} settings now',f'could you show {pane} preferences please',
                f'Jarvis, open {pane} settings for me.'][t],intent('settings.open'))
        for index in ('first','second','third','fourth','fifth'):
            for verb in ('open','preview','reveal'):
                add(split,'results',verb,[f'please {verb} the {index} result now',f'could you {verb} the {index} file please',
                    f'Jarvis, {verb} the {index} result for me.'][t],intent('files.result'))
        for on, variants in [(True,['please enable shuffle now','could you switch shuffle on please','Jarvis, turn shuffle on please.']),
                             (False,['please disable shuffle now','could you switch shuffle off please','Jarvis, turn shuffle off please.'])]:
            add(split,'shuffle','toggle'+str(on),variants[t].replace(' now',''),intent('media.shuffle'))
        for n in number_sets[split][:10]:
            add(split,'compound','app_volume',[
                f'please open Safari and set output volume to {words(n)} percent',
                f'could you open Chrome then lower volume by {words(n)} percent',
                f'Jarvis, open Brave and raise volume by {words(n)} percent.'][t],
                [intent('app.open',name=['Safari','Google Chrome','Brave Browser'][t]),
                 intent(['volume.set','volume.down','volume.up'][t],**{('level' if t==0 else 'by'):n})],slice='composition')
            add(split,'compound','workspace',[f'open a new Chrome window and open a new Brave tab',
                f'create a new tab in Chrome and open a new window in VS Code',
                f'Jarvis, open a new window in Brave and open a new tab in VS Code.'][t],
                [intent('app.new_tab' if t==1 else 'app.new_window'),intent('app.new_window' if t==1 else 'app.new_tab')],slice='composition')
        random.Random(7400+t).shuffle(result[split])
    return result


def main():
    rows=generate()
    BENCH.mkdir(parents=True,exist_ok=True)
    for split, path in [('train',SHARD),('development',BENCH/'development.jsonl'),('audit',BENCH/'audit.jsonl')]:
        path.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows[split]))
    manifest={'version':2,'supersedes':'generalization-v1: corrected unsupported smallest-file labels before any audit predictions were inspected; v1 development scores remain historical.',
              'policy':'Audit once after development selection; never train or select checkpoints on audit results.',
              'generator_sha256':digest(Path(__file__)),
              'files':{s:{'path':str(p.relative_to(ROOT)),'sha256':digest(p),'count':len(rows[s]),
                          'families':dict(Counter(r['family'] for r in rows[s]))}
                       for s,p in [('train',SHARD),('development',BENCH/'development.jsonl'),('audit',BENCH/'audit.jsonl')]}}
    (BENCH/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({s:len(v) for s,v in rows.items()}))


if __name__=='__main__': main()
