#!/usr/bin/env python3
"""Shard077: status/question distinctions and older file-operation retention.

Development/legacy regression families inform coverage; final audits stay closed.
"""
import json
from collections import Counter
from evaluation_data import ROOT, heldout_paths, text_key

OUTPUT=ROOT/'dataset/train-077-status-file-retention.jsonl'


def generate():
    blocked={text_key(json.loads(s)['text']) for p in [*ROOT.glob('dataset/*.jsonl'),*heldout_paths()]
             if p!=OUTPUT for s in p.read_text().splitlines() if s.strip()}
    rows=[]
    def i(intent_name,**args):return dict(name=intent_name,args=args)
    def add(family,template,text,labels):
        k=text_key(text)
        if k in blocked:return
        blocked.add(k);rows.append(dict(text=text,intents=labels if isinstance(labels,list) else [labels],family=family,template_id=f'train077:{family}:{template}'))
    reads={
        'info.battery':['remaining battery charge','battery percentage left','current battery power','remaining battery capacity','battery charge level','remaining charge on my Mac'],
        'info.bluetooth':['connected Bluetooth accessories','paired Bluetooth equipment','Bluetooth gadgets currently connected','active Bluetooth connections','Bluetooth devices connected right now','wireless Bluetooth accessories'],
        'info.wifi':['current Wi-Fi connection','wireless network status','Wi-Fi connectivity','active wireless network','current wifi signal','wifi connection status'],
        'info.time':['local clock time','time on my Mac','current clock time'],
        'info.date':['current calendar date','date on my Mac','today\'s calendar date'],
        'info.volume':['current volume','volume level','current volume level'],
        'info.brightness':['current screen brightness','current brightness level','display brightness level'],
        'info.contrast':['current screen contrast','current contrast level','display contrast level']}
    for name,subjects in reads.items():
        for subject in subjects:
            for k,text in enumerate([f'please report the {subject}',f'can you check the {subject} for me',f'let me know the {subject}',
                                    f'Jarvis, show me the {subject}.',f'what is the {subject} please']):
                add('info',name+str(k),text,i(name))
    for subject in ('battery charge','battery power','battery capacity'):
        for k,text in enumerate([f'how much {subject} is left right now',f'can you check how much {subject} is available',
                                f'please tell me the remaining {subject} percentage']):
            add('info','battery_amount'+str(k),text,i('info.battery'))
    for target in ('Bluetooth accessories','Bluetooth gadgets','Bluetooth equipment'):
        for k,text in enumerate([f'which {target} are connected to my Mac',f'please list the {target} hooked to my computer',
                                f'can you show which {target} are paired']):
            add('info','bluetooth_list'+str(k),text,i('info.bluetooth'))
    for target in ('microphone input','mic input','microphone recording','mic recording'):
        for verb in ('mute','unmute','disable','silence'):
            for prefix in ('please','can you please','Jarvis,'):
                text=f'{prefix} {verb} {target}'
                add('boundary','input'+verb+prefix,text,i('ai.query',text=text))
    for target in ('system audio','speaker audio','output sound'):
        for verb,name in [('mute','volume.mute'),('unmute','volume.unmute')]:
            for prefix in ('please','can you please','Jarvis,'):
                add('output_audio',verb+prefix,f'{prefix} {verb} {target}',i(name))
    for genre in ('soul','classical','ambient','folk','hip hop','reggae','blues','techno','disco','country','funk','punk'):
        for k,text in enumerate([f'play some {genre} music on Spotify please',f'could you put on some {genre} on Spotify',
                                f'I would like a {genre} playlist',f'start a playlist of {genre} music']):
            add('genre_playlist',str(k),text,i('media.play_playlist',name=genre))
    for folder in ('downloads','documents','desktop','pictures','movies','music'):
        add('files_query','list',f'please list the files inside my {folder} directory',i('files.query',op='list',folder=folder,ext=''))
        add('files_query','listFolders',f'can you list the subfolders in {folder} please',i('files.query',op='listFolders',folder=folder,ext=''))
        add('files_query','countFolders',f'please count the directories inside {folder}',i('files.query',op='countFolders',folder=folder,ext=''))
        for ext in ('zip','pdf','mp4','xlsx','txt'):
            for k,text in enumerate([f'please calculate the total size of {ext} files in {folder}',
                                    f'how many bytes are used by {ext} files in {folder}',
                                    f'tell me the combined storage used by {ext} files in {folder}']):
                add('files_query','totalSize'+str(k),text,i('files.query',op='totalSize',folder=folder,ext=ext))
            add('files_query','openNewest',f'please open the most recently saved {ext} in {folder}',i('files.query',op='openNewest',folder=folder,ext=ext))
            add('compound','open_latest_count',f'open my {folder} folder, then open the newest {ext} there and report the folder count',
                [i('folder.open',name=folder),i('files.query',op='openNewest',folder=folder,ext=ext),i('files.query',op='countFolders',folder=folder,ext='')])
    for prefix in ('please put speaker volume at','can you set the output volume to','Jarvis change audio to','could you adjust volume to'):
        for fraction,n in [('half',50),('one half',50),('a quarter',25),('three quarters',75)]:
            add('fraction_volume',prefix,prefix+' '+fraction,i('volume.set',level=n))
    for first,last in [('time','date'),('date','time')]:
        for text in [f'please give me the {first} followed by the {last}',f'can you tell me the {first} and then the {last}',f'Jarvis, report the {first} and the {last}.']:
            add('compound','info_sequence'+first,text,[i('info.'+first),i('info.'+last)])
    return rows


if __name__=='__main__':
    rows=generate();OUTPUT.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    print(len(rows),dict(Counter(r['family'] for r in rows)))
