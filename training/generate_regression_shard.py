#!/usr/bin/env python3
"""Author shard 073 from regression families, never from benchmark sentences.

Finite templates use synthetic names/topics. Existing train and held-out texts
are excluded (case/punctuation normalized). Native fields remain separate from
argument-free intent targets. Run from any directory; output is deterministic.
"""
from collections import Counter
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'dataset/train-073-regression-retention.jsonl'


def key(text):
    return re.sub(r'[^\w]+', ' ', text.casefold()).strip()


def generate():
    blocked = {key(json.loads(line)['text'])
               for path in [*ROOT.glob('dataset/*.jsonl'), *ROOT.glob('training/eval_*.jsonl')]
               if path != OUTPUT
               for line in path.read_text().splitlines() if line.strip()}
    rows, seen = [], set()

    def intent(intent_name, **args):
        return {'name': intent_name, 'args': args}

    def add(text, intents, family, resolved=None):
        k = key(text)
        if k in blocked or k in seen:
            return
        seen.add(k)
        row = {'text': text, 'intents': intents if isinstance(intents, list) else [intents],
               'regression_family': family}
        if resolved is not None:
            row['resolved_args'] = resolved
        rows.append(row)

    # Restore required string arguments, not only intent-family names.
    topics = ['how to repair a bicycle chain', 'public libraries in Jaipur',
              'why autumn leaves change color', 'beginner pottery tutorials',
              'overnight trains to Mysore', 'how to bake sourdough rolls',
              'rainwater collection methods', 'how to care for a bonsai tree',
              'quiet instrumental guitar music', 'basic astronomy for children']
    for engine, verb in [('Google', 'google'), ('YouTube', 'search youtube for'),
                         ('Reddit', 'search reddit for'), ('Bing', 'search bing for')]:
        for query in topics:
            for text in [f'{verb} {query} please', f'look up {query} on {engine} for me',
                         f'please search {engine} for {query}']:
                add(text, intent('web.search', engine=engine, query=query), 'web_arguments')
    for query in topics[:6]:
        add(f'open Google and find {query}', intent('web.search', engine='Google', query=query), 'web_arguments')
        add(f'search {query} in Brave Browser please', intent('web.search', engine='Google', query=query), 'web_arguments')

    for folder in ['downloads', 'documents', 'desktop', 'pictures', 'movies', 'music']:
        for text in [f'please show me my {folder} folder', f'open up the {folder} directory for me',
                     f'take me to {folder} please']:
            add(text, intent('folder.open', name=folder), 'folder_arguments')
        for text in [f'please open the newest file from {folder}', f'get the most recently saved file in {folder}',
                     f'open my latest file from the {folder} folder']:
            add(text, intent('file.open_latest', folder=folder), 'latest_file_arguments')
    for name in ['reading tracker', 'ceramics notes', 'winter itinerary', 'garden calendar',
                 'camera checklist', 'release sketch', 'weekly menu', 'study outline',
                 'workshop agenda', 'repair journal', 'training diary', 'recipe index']:
        for text in [f'please make a file named {name}', f'create a new file called {name} for me']:
            add(text, intent('file.create', name=name), 'creation_arguments')
        for text in [f'please make a folder named {name}', f'create a new folder called {name} for me']:
            add(text, intent('folder.create', name=name), 'creation_arguments')
    for package in ['jq', 'tree', 'ripgrep', 'bat', 'fzf', 'tmux', 'imagemagick', 'pandoc', 'sox', 'fd']:
        for text in [f'install {package} through homebrew please', f'please install {package} using brew',
                     f'preview installing {package} with homebrew']:
            add(text, intent('install.preview', package=package, source='homebrew'), 'install_arguments')

    songs = ['Yellow Submarine', 'Take Five', 'Moon River', 'Here Comes the Sun',
             'Blue in Green', 'Waterloo Sunset', 'Dream a Little Dream', 'Golden Slumbers',
             'Fields of Gold', 'Morning Has Broken', 'Across the Universe', 'Autumn Leaves']
    for title in songs:
        for text in [f'I feel like hearing {title}', f'put on the song {title} for me',
                     f'please play {title} on Spotify']:
            add(text, intent('media.play_song', title=title), 'media_arguments')
    for name in ['acoustic morning', 'late night piano', 'weekend cycling', 'ambient reading', 'rainy afternoon', 'evening jazz']:
        for text in [f'start the {name} playlist for me', f'please play my playlist called {name}',
                     f'put on playlist {name} on Spotify']:
            add(text, intent('media.play_playlist', name=name), 'media_arguments')
    for text, name in [('go back one song please', 'media.previous'), ('please replay the preceding track', 'media.previous'),
                       ('skip ahead one track please', 'media.next'), ('please pause my music now', 'media.pause'),
                       ('resume the current track please', 'media.play'), ('start my saved songs please', 'media.play_liked')]:
        add(text, intent(name), 'media_transport')

    numbers = [(7, 'seven'), (14, 'fourteen'), (22, 'twenty two'), (29, 'twenty nine'),
               (37, 'thirty seven'), (46, 'forty six'), (53, 'fifty three'), (61, 'sixty one'),
               (68, 'sixty eight'), (74, 'seventy four'), (83, 'eighty three'), (92, 'ninety two')]
    for n, word in numbers:
        for text in [f'could you set speaker volume to {word} percent', f'please put output sound at {n} percent',
                     f'raise the sound to {word} percent please', f'reduce the sound to {n} percent please']:
            add(text, intent('volume.set', level=n), 'volume')
        if n <= 37:
            add(f'please raise system volume by {word} percentage points', intent('volume.up', by=n), 'volume')
            add(f'lower my output sound by {n} percent please', intent('volume.down', by=n), 'volume')
        add(f'set display brightness to {n} percent please', intent('display.brightness_set', level=n), 'display_arguments')
        add(f'please set screen contrast to {n} percent', intent('display.contrast_set', level=n), 'display_arguments')
    for n in [4, 6, 11, 17, 21, 24]:
        add(f'could you brighten the display by {n} percent', intent('display.brightness_up', by=n), 'display_arguments')
        add(f'please dim my screen by {n} percent', intent('display.brightness_down', by=n), 'display_arguments')
        add(f'raise screen contrast by {n} please', intent('display.contrast_up', by=n), 'display_arguments')
    for text, name in [('can you please show the volume', 'info.volume'), ('Jarvis what is the current volume level please', 'info.volume'),
                       ('could you please check volume', 'info.volume'), ('Jarvis how loud is the volume please', 'info.volume'),
                       ('could you mute system audio please', 'volume.mute'), ('could you unmute system audio please', 'volume.unmute'),
                       ('please set speaker volume to fifty percent', 'volume.set')]:
        add(text, intent(name, **({'level': 50} if name == 'volume.set' else {})), 'volume')

    for app, canonical in [('VS Code', 'Visual Studio Code'), ('Chrome', 'Google Chrome'), ('Brave', 'Brave Browser'),
                           ('Finder', 'Finder'), ('Safari', 'Safari'), ('Terminal', 'Terminal'), ('Spotify', 'Spotify'), ('Notes', 'Notes')]:
        add(f'could you open {app} for me', intent('app.open', name=canonical), 'app_arguments')
        add(f'please close the {app} app', intent('app.close', name=canonical), 'app_arguments')
        add(f'launch {app} now please', intent('app.open', name=canonical), 'app_arguments')
    for text, name in [('please check whether bluetooth is enabled', 'info.bluetooth'), ('tell me if wifi is connected please', 'info.wifi'),
                       ('please report my battery level', 'info.battery'), ('tell me today\'s date please', 'info.date'),
                       ('please tell me the local time', 'info.time')]:
        add(text, intent(name), 'info')
    add('please tell me the time followed by the date', [intent('info.time'), intent('info.date')], 'compound')
    for text in ['what is a microphone array', 'explain how active noise cancellation works',
                 'what does an audio sample rate describe', 'why do speakers need an amplifier',
                 'explain what a virtual audio interface does', 'how do digital cameras focus']:
        add(text, intent('ai.query', text=text), 'ai_boundary')
    for idx in range(10):
        n=idx+13; playlist=['acoustic morning', 'late night piano'][idx%2]
        add(f'increase brightness by {n} and play the {playlist} playlist and set volume to {n+30}',
            [intent('display.brightness_up', by=n), intent('media.play_playlist', name=playlist), intent('volume.set', level=n+30)], 'compound')
        add(f'open Safari and set speaker volume to {n+20} percent',
            [intent('app.open', name='Safari'), intent('volume.set', level=n+20)], 'compound')

    # Retention examples include on/off and distinguish shuffle from transport.
    for verb in ['please turn the shuffle mode on', 'could you switch shuffle on', 'please set the shuffle mode on',
                 'please turn the shuffle mode off', 'could you switch shuffle off', 'please set the shuffle mode off']:
        enabled=not ('off' in verb or 'disable' in verb)
        add(verb, intent('media.shuffle'), 'shuffle_retention', {'target':'current','name':'','enabled':enabled})
    for name in ['coastal walk', 'quiet coding', 'sunrise drive', 'piano practice', 'weekend brunch', 'forest trail']:
        for text, enabled in [(f'play playlist {name} in shuffle mode',True), (f'play my {name} playlist without shuffle please',False),
                              (f'shuffle the {name} playlist please',True)]:
            add(text,intent('media.shuffle'),'shuffle_retention',{'target':'playlist','name':name,'enabled':enabled})
    for text, enabled in [('play my saved songs in random order please',True), ('play liked songs in order please',False),
                          ('please shuffle all of my favorites',True), ('play songs from liked songs without shuffle please',False)]:
        add(text,intent('media.shuffle'),'shuffle_retention',{'target':'liked','name':'','enabled':enabled})

    def workspace(text, operation, app, project='', root=''):
        family={'newWindow':'app.new_window','newTab':'app.new_tab','newTerminalTab':'app.new_tab','openProject':'project.open'}[operation]
        add(text,intent(family),'workspace_retention',[{'operation':operation,'app':app,'project':project,'root':root}])
    for name, app in [('Chrome','chrome'),('Brave Browser','brave'),('Visual Studio Code','vscode')]:
        for kind, op in [('window','newWindow'),('tab','newTab')]:
            for text in [f'could you please create one new {kind} for {name}',f'can you open a new {name} {kind}',
                         f'please make one new {kind} on {name}']:
                workspace(text,op,app)
    for project in ['harbor catalog','cedar-tools','lunar diary','maple dashboard','cobalt-notes','starlight api','cloud garden','river atlas']:
        for name, app in [('Finder','finder'),('VS Code','vscode'),('Terminal','terminal')]:
            workspace(f'could you please open my {project} project with {name}','openProject',app,project)
            workspace(f'open {project} project from experiments in {name}','openProject',app,project,'experiments')
    for app,name in [('finder','Finder'),('vscode','VS Code'),('terminal','Terminal')]:
        workspace(f'could you please open that project in {name}','openProject',app,'@recent')
    workspace('please make a new terminal tab in VS Code','newTerminalTab','vscode')
    workspace('can you create one new editor tab in Visual Studio Code','newTab','vscode')

    for query in ['telescope logbook','harvest schedule','studio inventory','ceramics handbook','trail journal','shipping checklist','museum itinerary','camera warranty']:
        add(f'find the {query} document',intent('files.search'),'native_retention',{'query':query,'mode':'name','kind':'any','scope':'','date':'any','min_bytes':0,'max_bytes':0})
        add(f'find PDFs containing {query}',intent('files.search'),'native_retention',{'query':query,'mode':'content','kind':'pdf','scope':'','date':'any','min_bytes':0,'max_bytes':0})
    return rows


if __name__ == '__main__':
    rows=generate()
    OUTPUT.write_text(''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in rows))
    print(f'{OUTPUT.name}: {len(rows)} rows')
    print(json.dumps(dict(Counter(row['regression_family'] for row in rows)),indent=2))
