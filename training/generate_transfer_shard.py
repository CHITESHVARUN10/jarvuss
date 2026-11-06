#!/usr/bin/env python3
"""Fresh shard075: diverse copy/contrast/composition examples, no audit reuse."""
from collections import Counter
import itertools
import json

from evaluation_data import ROOT, heldout_paths, text_key

OUTPUT=ROOT/'dataset/train-075-slot-transfer.jsonl'


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
                         template_id=f'train075:{family}:{template}'))
    names=[' '.join(parts) for parts in itertools.product(
        ['sunlit','painted','wooden','gentle','distant','wandering','hidden','rustic'],
        ['bridge','orchid','fountain','shelter','station','ribbon'])]
    for j,name in enumerate(names):
        for kind in ('file','folder'):
            for k,text in enumerate([f'make a new {kind} with the name {name}',f'could you create a {kind} called {name} please',
                                     f'Jarvis, create the {kind} named {name} for me.']):
                add('creation',kind+str(k),text,i(kind+'.create',name=name))
        for k,text in enumerate([f'put on some {name}',f'I feel like listening to {name}',f'can you play the song {name} please']):
            add('media','song'+str(k),text,i('media.play_song',title=name))
        for k,text in enumerate([f'play playlist named {name} please',f'put on my {name} playlist',f'could you start the playlist called {name}']):
            add('media','playlist'+str(k),text,i('media.play_playlist',name=name))
        for engine in ('Google','YouTube','Bing','Reddit'):
            query=name+[' and the morning sky',' and fire safety',' and the distant shore',' restoration'][j%4]
            add('web',engine,f'please search {engine} for {query} now',i('web.search',engine=engine,query=query))
            add('web',engine+'prefix',f'could you look up {query} on {engine} please',i('web.search',engine=engine,query=query))
        for app in ('Finder','VS Code','Terminal'):
            add('workspace','project'+app,f'please open my {name} project in {app}',i('project.open'))
        for suffix in ('on shuffle','without shuffle','sequentially'):
            add('shuffle',suffix,f'please play playlist called {name} {suffix}',i('media.shuffle'))
        add('compound','project',f'open {name} project in Finder and then open it in Terminal',[i('project.open'),i('project.open')])
        n=(j*7)%99+1
        add('compound','volume',f'open Brave then set volume to {n} and pause the music',
            [i('app.open',name='Brave Browser'),i('volume.set',level=n),i('media.pause')])
        add('native_search','name',f'please locate files named {name}',i('files.search'))
    for j in range(1,25):
        for scheme in ('http','https'):
            url=f'{scheme}://sample{j}.example.org/reference-{j}'
            for k,text in enumerate([f'go to {url}',f'could you visit {url} please']):
                add('urls','plain'+str(k),text,i('url.open',url=url))
            for app,canonical in [('Chrome','Google Chrome'),('Brave','Brave Browser'),('Safari','Safari')]:
                add('urls',app,f'open {url} using {app}',i('url.open_in',url=url,browser=canonical))
    for folder in ('downloads','documents','desktop','pictures','movies','music'):
        for op,verb in [('largest','largest'),('smallest','smallest'),('newest','newest'),('oldest','oldest')]:
            for k,text in enumerate([f'which is the {verb} file in {folder} please',f'show me the {verb} files inside {folder}']):
                add('boundary' if op=='smallest' else 'files_query',op+str(k),text,
                    i('ai.query',text=text) if op=='smallest' else i('files.query',op=op,folder=folder,ext=''))
        for ext in ('pdf','xlsx','txt'):
            add('files_query','typed',f'open the newest {ext} in {folder} please',i('files.query',op='openNewest',folder=folder,ext=ext))
            add('compound','folder_query',f'open {folder}, open the latest {ext} and count folders in {folder}',
                [i('folder.open',name=folder),i('files.query',op='openNewest',folder=folder,ext=ext),
                 i('files.query',op='countFolders',folder=folder,ext='')])
    topics=['why audio inputs differ from outputs','how browser window groups work','what microphone gain does',
            'how a sound mixer works','why playlists repeat songs','how to organize software projects',
            'what a speaker driver does','how monitors adjust contrast','why computers sleep','how search engines rank pages',
            'why keyboard shortcuts differ between apps','what a terminal emulator does','how file extensions work',
            'what microphone mute means','how bookmarks differ from tabs','why headphones need an amplifier']
    for topic in topics:
        for k,text in enumerate([f'explain {topic}',f'can you explain {topic} please',f'Jarvis, tell me {topic}.',f'I would like to understand {topic}']):
            add('boundary','explain'+str(k),text,i('ai.query',text=text))
    for action in ('mute the mic','turn off the microphone','raise microphone gain','turn the camera on','lower input sensitivity'):
        for k,text in enumerate([action+' please', 'could you '+action, 'Jarvis, '+action+'.']):
            add('boundary','unsupported'+str(k),text,i('ai.query',text=text))
    for phrase in ('the selected result','that','it','the first result','the third file','the seventh one'):
        for verb in ('open','preview','quick look','reveal','show in Finder'):
            add('results',verb,f'could you {verb} {phrase} please',i('files.result'))
    for pane in ('Bluetooth','Wi-Fi','Sound','Privacy','Displays','Keyboard','Mouse','Trackpad'):
        for prefix in ('please open','could you show','Jarvis open'):
            add('settings',prefix,f'{prefix} {pane} settings',i('settings.open'))
    for phrase in ('shuffle mode on','shuffle mode off','shuffle on','shuffle off'):
        for prefix in ('could you set','please switch','Jarvis turn'):
            add('shuffle','toggle'+prefix,f'{prefix} {phrase}',i('media.shuffle'))
    for songs in ('favorites','favourites','liked songs','saved songs','favorite tracks'):
        for suffix in ('on shuffle','in order','in random order','sequentially','without shuffle'):
            add('shuffle','liked'+suffix,f'could you play my {songs} {suffix} please',i('media.shuffle'))
    for app,canonical in [('Chrome','Google Chrome'),('Brave','Brave Browser'),('VS Code','Visual Studio Code'),('Spotify','Spotify')]:
        for verb in ('open','close'):
            for prefix in ('can you','please','Jarvis'):
                add('apps',verb+prefix,f'{prefix} {verb} {app} please',i('app.'+verb,name=canonical))
        if app=='Spotify':continue
        for kind in ('window','tab'):
            for verb in ('open','create','make'):
                add('workspace',verb+kind,f'can you please {verb} one new {kind} for {app}',i('app.new_'+kind))
    for app in ('VS Code','Visual Studio Code'):
        for verb in ('open','create','make'):
            add('workspace','terminal'+verb,f'could you please {verb} a new terminal tab in {app}',i('app.new_tab'))
    for phrase,name in [('rewind the track','media.previous'),('go back a song','media.previous'),('replay the previous track','media.previous'),
                        ('play music','media.play'),('stop the music','media.pause'),('skip the song','media.next')]:
        for prefix in ('please','could you','Jarvis'):
            add('transport',prefix,f'{prefix} {phrase} please',i(name))
    for text,n in [('put the volume at half please',50),('please set volume to a quarter',25),('volume at three quarters please',75)]:
        add('fraction_volume','fraction',text,i('volume.set',level=n))
    return rows


if __name__=='__main__':
    rows=generate();OUTPUT.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    print(len(rows),dict(Counter(r['family'] for r in rows)))
