#!/usr/bin/env python3
"""Shard078: negation/quotation contrasts, native name search, teen numbers.

Fresh sentences address consumed-audit failure families. A new audit edition
must be frozen before another model is selected. Prior audit sentences remain
excluded, even though their failure families are now known.
"""
import json
from collections import Counter
from evaluation_data import ROOT, heldout_paths, text_key

OUTPUT=ROOT/'dataset/train-078-context-literals.jsonl'


def generate():
    blocked={text_key(json.loads(s)['text']) for p in [*ROOT.glob('dataset/*.jsonl'),*heldout_paths()]
             if p!=OUTPUT for s in p.read_text().splitlines() if s.strip()}
    rows=[]
    def i(intent_name,**args):return dict(name=intent_name,args=args)
    def add(family,template,text,labels):
        k=text_key(text)
        if k in blocked:return
        blocked.add(k);rows.append(dict(text=text,intents=labels if isinstance(labels,list) else [labels],family=family,template_id=f'train078:{family}:{template}'))
    apps=[('Safari','Safari'),('Chrome','Google Chrome'),('Brave','Brave Browser'),('VS Code','Visual Studio Code'),
          ('Spotify','Spotify'),('Terminal','Terminal'),('Finder','Finder'),('Notes','Notes')]
    commands=[]
    for app,canonical in apps:
        for verb in ('open','close'):
            commands.append((f'{verb} {app}',i('app.'+verb,name=canonical)))
    for app in ('Chrome','Brave','VS Code'):
        for kind in ('tab','window'):commands.append((f'create a new {kind} in {app}',i('app.new_'+kind)))
    commands += [('mute system audio',i('volume.mute')),('unmute system audio',i('volume.unmute')),
                 ('turn shuffle off',i('media.shuffle')),('turn shuffle on',i('media.shuffle')),
                 ('set volume to thirty three percent',i('volume.set',level=33))]
    for command,label in commands:
        for k,text in enumerate([f'please never {command}',f'I do not want you to {command}',f'please do not {command} right now',
                                f'could you avoid trying to {command}',f'don\'t {command} for me']):
            add('boundary','negation'+str(k),text,i('ai.query',text=text))
        for k,text in enumerate([f'can you explain the phrase "{command}"',f'I am discussing the command "{command}", not asking you to execute it',
                                f'what is meant by "{command}"',f'tell me what "{command}" means without doing it']):
            add('boundary','quoted'+str(k),text,i('ai.query',text=text))
        # Positive controls use the same action words; off and close are actions.
        for prefix in ('Jarvis, please','could you please'):
            add('positive_control',prefix,prefix+' '+command,label)
    names=['Auburn Voyage','Banyan Sketch','Ceramic Mosaic','Dahlia Almanac','Elderberry Pier','Fennel Almanac',
           'Gilded Orchard','Helium Lantern','Ivory Junction','Kestrel Studio','Lagoon Almanac','Meadow Almanac',
           "Harper's Atlas",'Café Aurora','Beacon_Kit-57','Orchid Notes 304']
    for name in names:
        for typ in ('file','folder'):
            for k,text in enumerate([f'please create a {typ} named "{name}"',f'make me a {typ} called {name}',
                                    f'could you make a {typ} with the name "{name}" please']):
                add('copy',typ+str(k),text,i(typ+'.create',name=name))
        for k,text in enumerate([f'play the song "{name}" please',f'put on the song {name} in Spotify',f'I want to hear the song {name}']):
            add('copy','song'+str(k),text,i('media.play_song',title=name))
        for engine in ('Google','Bing','YouTube'):
            add('copy','web'+engine,f'please look up "{name} and the desert sky" on {engine}',
                i('web.search',engine=engine,query=name+' and the desert sky'))
        for verb in ('search for files called','search for documents named','locate files titled','find files called'):
            for prefix in ('please','could you please'):
                add('native_search',verb+prefix,prefix+' '+verb+' '+name,i('files.search'))
    # Names containing imperative words remain literal arguments when an actual
    # play/create/search instruction introduces them.
    for title in ['Never Close the Gate','Do Not Wake the Moon','Turn Off the Rain','Open Another Horizon',
                  'Do Not Mute the Stars','Please Stay Awake','Close Every Umbrella','Shuffle the Seasons']:
        add('copy','literal_song',f'please play the song "{title}" on Spotify',i('media.play_song',title=title))
        add('copy','literal_file',f'create a file called "{title}" please',i('file.create',name=title))
        add('copy','literal_search',f'search Bing for "{title}" please',i('web.search',engine='Bing',query=title))
    for n,word in [(13,'thirteen'),(14,'fourteen'),(15,'fifteen'),(16,'sixteen'),(17,'seventeen'),(18,'eighteen'),(19,'nineteen'),
                   (30,'thirty'),(40,'forty'),(50,'fifty'),(60,'sixty'),(70,'seventy'),(80,'eighty'),(90,'ninety')]:
        for op,verb,prep in [('set','adjust','to'),('up','boost','by'),('down','decrease','by')]:
            for k,text in enumerate([f'please {verb} speaker sound {prep} {word} percent',
                                    f'can you {verb} my audio {prep} {word} percentage points',
                                    f'Jarvis, {verb} output volume {prep} {n} percent.']):
                add('volume',op+str(k),text,i('volume.'+op,**{('level' if op=='set' else 'by'):n}))
    return rows


if __name__=='__main__':
    rows=generate();OUTPUT.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    print(len(rows),dict(Counter(r['family'] for r in rows)))
