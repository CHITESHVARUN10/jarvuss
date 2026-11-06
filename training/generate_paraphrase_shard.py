#!/usr/bin/env python3
"""Shard079: broad paraphrase/component transfer, excluding all benchmarks."""
import json
from collections import Counter
from evaluation_data import ROOT,heldout_paths,text_key

OUTPUT=ROOT/'dataset/train-079-paraphrase-composition.jsonl'


def generate():
    blocked={text_key(json.loads(s)['text']) for p in [*ROOT.glob('dataset/*.jsonl'),*heldout_paths()]
             if p!=OUTPUT for s in p.read_text().splitlines() if s.strip()}
    rows=[]
    def i(intent_name,**args):return dict(name=intent_name,args=args)
    def add(family,template,text,labels):
        key=text_key(text)
        if key in blocked:return
        blocked.add(key);rows.append(dict(text=text,intents=labels if isinstance(labels,list) else [labels],family=family,template_id=f'train079:{family}:{template}'))
    names=['Boreal Index','Cloudstone Report','Dappled Almanac','Evergreen Lab','Foxglove Ledger','Garnet Workshop',
           'Hawthorn Folio','Iris Almanac','Jasper Memoir','Lupine Studio','Magnolia Journal','Nightingale Compass']
    for app,canonical in [('Chrome','Google Chrome'),('Brave','Brave Browser'),('VS Code','Visual Studio Code'),('Finder','Finder'),
                           ('Terminal','Terminal'),('Safari','Safari'),('Spotify','Spotify'),('Notes','Notes')]:
        for k,text in enumerate([f'get {app} running please',f'I would like you to launch {app}',f'could you start up {app}',
                                f'please bring up the {app} application',f'I need {app} opened now']):add('apps','open'+str(k),text,i('app.open',name=canonical))
        for k,text in enumerate([f'I would like you to quit {app}',f'please shut down the {app} application',f'could you exit {app}',
                                f'I need the {app} application closed',f'terminate {app} please']):add('apps','close'+str(k),text,i('app.close',name=canonical))
    for idx,base_name in enumerate(names):
        forms=[base_name,base_name.lower(),base_name.upper()]
        for typ in ('file','folder'):
            for k in range(4):
                name=forms[(idx+k)%3]
                text=[f'I would like a {typ} with the name {name}',f'could you create me a {typ} named "{name}"',
                      f'make a {typ} for me and call it {name}',f'please create the new {typ} "{name}"'][k]
                add('creation',typ+str(k),text,i(typ+'.create',name=name))
        for engine in ('Google','Bing','YouTube','Reddit'):
            for k in range(4):
                query=forms[(idx+k)%3]+' maintenance methods'
                text=[f'find information on {query} through {engine}',f'look for information about {query} using {engine}',
                      f'could you use {engine} to find {query}',f'please do a {engine} search on "{query}"'][k]
                add('web',engine+str(k),text,i('web.search',engine=engine,query=query))
        for k in range(3):
            name=forms[(idx+k)%3]
            text=[f'let us listen to the song "{name}"',f'start the song called {name}',f'I would like you to play {name} on Spotify'][k]
            add('media','song'+str(k),text,i('media.play_song',title=name))
        for k in range(3):
            name=forms[(idx+k)%3]
            text=[f'let us listen to my {name} playlist',f'could you start playing the playlist {name}',f'I would like the playlist named "{name}"'][k]
            add('media','playlist'+str(k),text,i('media.play_playlist',name=name))
        name=base_name
        for app in ('Finder','VS Code','Terminal'):
            add('workspace','project',f'can you please open project {name} from demos on {app}',i('project.open'))
        for text in [f'please search files titled {name}',f'locate a document named "{name}"',f'could you find the document {name}']:
            add('native_search','names',text,i('files.search'))
        for text in [f'play the {name} playlist shuffled',f'play playlist called {name} with shuffle on',f'play playlist {name} with shuffle off']:
            add('shuffle','playlist',text,i('media.shuffle'))
        topic=f'what the fictional title "{name}" suggests'
        text='I would like you to explain '+topic
        add('boundary','explain',text,i('ai.query',text=text))
    for folder in ('downloads','documents','desktop','pictures','movies','music'):
        for k,text in enumerate([f'bring me to my {folder} directory please',f'I would like to see my {folder} folder',
                                f'please bring the {folder} folder up',f'take me into the {folder} directory']):
            add('folders','open'+str(k),text,i('folder.open',name=folder))
        for k,text in enumerate([f'get the latest file from {folder} and open it for me',f'I need you to open my newest file inside {folder}',
                                f'please retrieve and open the last saved file in {folder}',f'bring up the most recent file from {folder}']):
            add('folders','latest'+str(k),text,i('file.open_latest',folder=folder))
        phrases={
            'count':[f'report the number of files stored inside {folder}',f'give me a count of all files within {folder}'],
            'countFolders':[f'report the number of subdirectories inside {folder}',f'how many subfolders does {folder} contain'],
            'list':[f'enumerate the files within {folder}',f'give me a listing of filenames inside {folder}'],
            'listFolders':[f'enumerate subdirectories within {folder}',f'give me a listing of folder names inside {folder}'],
            'largest':[f'find the file with the greatest size inside {folder}',f'which item occupies the most storage in {folder}'],
            'oldest':[f'identify the earliest saved file inside {folder}',f'which file was saved first in {folder}'],
            'newest':[f'identify the last saved file inside {folder}',f'which file was saved most recently in {folder}'],
            'totalSize':[f'calculate the combined storage footprint of files inside {folder}',f'what is the aggregate size of files in {folder}'],
            'openNewest':[f'bring up the last modified file inside {folder}',f'open the last saved file within {folder}'],
            'openOldest':[f'bring up the earliest file saved inside {folder}',f'open the first saved file within {folder}']}
        for op,texts in phrases.items():
            for k,text in enumerate(texts):
                # Unfiltered newest-file opening has an existing canonical
                # shortcut. Reserve files.query/openNewest for typed filters.
                label=i('file.open_latest',folder=folder) if op=='openNewest' else i('files.query',op=op,folder=folder,ext='')
                add('folders' if op=='openNewest' else 'files_query',op+str(k),text,label)
    statuses={'battery':['battery charge left','amount of battery power available','battery percentage'],
              'bluetooth':['Bluetooth accessories currently paired','Bluetooth devices currently linked','connected Bluetooth equipment'],
              'wifi':['wireless network connection','Wi-Fi connectivity right now','wireless network name'],
              'time':['clock time right now','local time on this computer','current time'],
              'date':['calendar date right now','date on this computer','current date'],
              'volume':['output volume level','system sound level','current speaker volume'],
              'brightness':['screen brightness percentage','display brightness setting','current brightness'],
              'contrast':['screen contrast setting','display contrast percentage','current contrast']}
    for suffix,subjects in statuses.items():
        for subject in subjects:
            for k,text in enumerate([f'read out the {subject} please',f'could you give me the {subject}',f'I need to know the {subject}']):
                add('info',suffix+str(k),text,i('info.'+suffix))
    for idx in range(1,13):
        url=f'https://guide{idx}.example.net/manual-{idx}'
        for k,text in enumerate([f'please browse {url}',f'could you load the website {url}',f'I need you to visit {url}']):
            add('urls','plain'+str(k),text,i('url.open',url=url))
        for app,canonical in [('Chrome','Google Chrome'),('Brave','Brave Browser'),('Safari','Safari')]:
            add('urls',app,f'please visit the site {url} with {app}',i('url.open_in',url=url,browser=canonical))
    for package in ('jq','ripgrep','tree','fd','bat','tmux','fzf','pandoc'):
        for k,text in enumerate([f'please get {package} installed via Homebrew',f'I need you to install {package} from brew',
                                f'can you prepare a homebrew installation of {package}']):
            add('install',str(k),text,i('install.preview',package=package,source='homebrew'))
    for n in (12,17,24,33,42,56,69,78,84,93):
        for attr in ('brightness','contrast'):
            for op,verb,prep in [('set','put','at'),('up','raise','by'),('down','reduce','by')]:
                text=f'could you {verb} the screen {attr} {prep} {n} percent now'
                add('display',attr+op,text,i('display.'+attr+'_'+op,**{('level' if op=='set' else 'by'):n}))
    for name,phrases in {'media.play':['continue the music','carry on playing music'],
                         'media.pause':['halt the current music','stop playback for a moment'],
                         'media.next':['move forward to the next track','jump to the following song'],
                         'media.previous':['return to the last track','go to the preceding song'],
                         'media.play_liked':['start up the songs I saved','play all the songs I liked'],
                         'volume.mute':['mute system audio','silence the speakers'],
                         'volume.unmute':['unmute system audio','restore speaker audio']}.items():
        for phrase in phrases:
            for prefix in ('I need you to','please','can you'):
                add('transport',prefix,prefix+' '+phrase,i(name))
    for app in ('Chrome','Brave Browser','VS Code'):
        for kind in ('window','tab'):
            add('workspace','new'+kind,f'can you make one new {app} {kind}',i('app.new_'+kind))
    add('workspace','terminal','could you make one new terminal tab in VS Code',i('app.new_tab'))
    for text in ['please switch shuffle mode on','please switch shuffle mode off','could you enable shuffle','could you disable shuffle']:
        add('shuffle','toggle',text,i('media.shuffle'))
    for pane in ('Wi-Fi','Bluetooth','Sound','Privacy','Display'):
        add('settings','pane',f'would you please show {pane} settings',i('settings.open'))
    for ordinal in ('second','fourth','sixth','eighth'):
        for verb in ('open','preview','reveal'):
            add('results',verb,f'please {verb} result {ordinal}',i('files.result'))
    for idx in range(10):
        n=idx*7+11;name=names[idx]
        add('compound','file_volume',f'create a file called {name} and set output volume to {n} percent',
            [i('file.create',name=name),i('volume.set',level=n)])
    return rows


if __name__=='__main__':
    rows=generate();OUTPUT.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    print(len(rows),dict(Counter(r['family'] for r in rows)))
