#!/usr/bin/env python3
"""Shard076: question/action contrasts, rare slot copying and retention.

Authored from DEVELOPMENT error families only. No final audit outputs are read.
"""
import itertools
import json
from collections import Counter

from evaluation_data import ROOT, heldout_paths, text_key

OUTPUT=ROOT/'dataset/train-076-boundary-copy.jsonl'


def generate():
    blocked={text_key(json.loads(s)['text']) for p in [*ROOT.glob('dataset/*.jsonl'),*heldout_paths()]
             if p!=OUTPUT for s in p.read_text().splitlines() if s.strip()}
    rows=[]
    def i(intent_name,**args):return dict(name=intent_name,args=args)
    def add(family,template,text,labels):
        k=text_key(text)
        if k in blocked:return
        blocked.add(k)
        rows.append(dict(text=text,intents=labels if isinstance(labels,list) else [labels],family=family,
                         template_id=f'train076:{family}:{template}'))
    subjects=['how browser tabs are created','why a new window is useful','what happens when speakers are muted',
        'how keyboard volume buttons work','why songs play in random order','what playlist shuffle means',
        'how a file preview is generated','how a terminal tab differs from an editor tab','how battery capacity is measured',
        'what a software project root means','why microphone gain changes loudness','how cameras adjust exposure',
        'why a file manager sorts by size','how desktop folders are organized','why screens have brightness settings',
        'how Bluetooth audio devices connect','how Wi-Fi signal strength works','why a paused track stays selected',
        'how an app closes its windows','what a file extension indicates','why web searches use keywords',
        'how homebrew installs software','what contrast does to a display','how the current date is calculated']
    for topic in subjects:
        for k,text in enumerate([f'can you tell me {topic}',f'please explain to me {topic}',f'I have a question: {topic}',
                                f'could you explain the following: {topic}',f'Jarvis, explain {topic} please.',
                                f'what can you tell me about {topic}',f'help me understand {topic}',f'tell me {topic}, please']):
            add('boundary','question'+str(k),text,i('ai.query',text=text))
    for topic in ['enable microphone monitoring','mute microphone input','turn off camera recording','adjust microphone sensitivity',
                  'change keyboard backlight color','delete every file permanently','send an email to a friend','record a video']:
        for prefix in ('please','can you','could you please','Jarvis,'):
            text=prefix+' '+topic
            add('boundary','unsupported'+prefix,text,i('ai.query',text=text))
    for folder in ('downloads','documents','desktop','pictures','movies','music'):
        for prefix in ('please show me','can you list','Jarvis show','could you locate'):
            text=f'{prefix} the smallest files inside {folder}'
            add('boundary','unsupported_smallest'+prefix,text,i('ai.query',text=text))
        for ext in ('pdf','txt','mp4','xlsx'):
            add('compound','folder_open_count',f'please open {folder} and then open the most recent {ext} and count the folders there',
                [i('folder.open',name=folder),i('files.query',op='openNewest',folder=folder,ext=ext),
                 i('files.query',op='countFolders',folder=folder,ext='')])
    # New strings assembled independently of every benchmark slot pool. Names
    # with unusual subword boundaries discourage common-word substitution.
    names=[' '.join(p) for p in itertools.product(
        ['azalea','calyx','gossamer','larch','lichen','moraine','myrtle','tamarind','vesper','yucca'],
        ['chronicle','odyssey','panorama','reverie','synthesis','waypoint'])]
    for j,name in enumerate(names):
        for typ in ('file','folder'):
            add('copy',typ,f'please make the {typ} called {name} for me',i(typ+'.create',name=name))
        add('copy','song',f'could you play {name} in Spotify please',i('media.play_song',title=name))
        add('copy','playlist',f'I would like you to play my playlist {name}',i('media.play_playlist',name=name))
        for engine in ('Google','Bing'):
            add('copy',engine,f'look for {name} instructions on {engine} please',i('web.search',engine=engine,query=name+' instructions'))
        for browser in ('Brave','Chrome','Safari'):
            add('web','browser'+browser,f'please search for {name} in {browser}',i('web.search',engine='Google',query=name))
        phrase='could you describe '+name+' as a fictional landscape'
        add('boundary','copy',phrase,i('ai.query',text=phrase))
    for prefix in ('please','can you please','would you','Jarvis, please'):
        for verb in ('open','preview','quick look','reveal'):
            for ordinal in ('first','second','third','fourth','fifth','sixth','seventh','eighth'):
                add('results',prefix+verb,f'{prefix} {verb} the {ordinal} file',i('files.result'))
            for target in ('the selected file','that','this'):
                add('results',prefix+verb+'selected',f'{prefix} {verb} {target}',i('files.result'))
    for prefix in ('please','can you please','would you','Jarvis, please'):
        for verb in ('set','turn','switch'):
            for state in ('on','off'):
                add('shuffle','toggle'+prefix+verb,f'{prefix} {verb} shuffle mode {state}',i('media.shuffle'))
        for target in ('my favorites','liked songs','my saved songs'):
            for state in ('sequentially','in order','on shuffle','without shuffle'):
                add('shuffle','collection'+prefix+state,f'{prefix} play {target} {state}',i('media.shuffle'))
    for prefix in ('please','could you please','Jarvis,'):
        for phrase in ('rewind one song','go back to the earlier track','replay the last song','rewind the previous song'):
            add('transport',prefix,prefix+' '+phrase,i('media.previous'))
        for phrase in ('check battery charge','show how much battery is left','report remaining battery','tell me the battery percentage'):
            add('info',prefix,prefix+' '+phrase,i('info.battery'))
    for n,word in [(9,'nine'),(18,'eighteen'),(27,'twenty seven'),(36,'thirty six'),(45,'forty five'),(54,'fifty four'),
                   (63,'sixty three'),(72,'seventy two'),(81,'eighty one'),(90,'ninety')]:
        for verb in ('lower','reduce','raise','increase'):
            for representation in (str(n),word):
                add('volume',verb,f'can you please {verb} my volume to {representation} percent',i('volume.set',level=n))
    for fraction,n in [('half',50),('a quarter',25),('three quarters',75)]:
        for prefix in ('please put my volume at','set the sound to','can you turn the volume to'):
            add('fraction_volume',prefix,prefix+' '+fraction,i('volume.set',level=n))
    return rows


if __name__=='__main__':
    rows=generate();OUTPUT.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    print(len(rows),dict(Counter(r['family'] for r in rows)))
