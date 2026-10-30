#!/usr/bin/env python3
"""Local client for opt-in Jarvis command testing. No audio or external dependencies."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError("Test endpoint redirected; credentials were not forwarded")

class Client:
    def __init__(self, session):
        value = json.loads(Path(session).read_text())
        port, self.token = value.get("port"), value.get("token")
        if type(port) is not int or not 1 <= port <= 65535 or not isinstance(self.token, str) or not 32 <= len(self.token) <= 128:
            raise RuntimeError("Invalid test session file")
        self.base = f"http://127.0.0.1:{port}"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def request(self, path, body=None):
        headers = {"X-Jarvis-Test-Token": self.token, "Host": self.base.split('//')[1]}
        data = None
        if body is not None:
            data = json.dumps(body).encode(); headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(self.base+path, data=data, headers=headers)
        try:
            with self.opener.open(request, timeout=10) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try: message = json.load(error).get('error', f'HTTP {error.code}')
            except (ValueError, AttributeError): message = f'HTTP {error.code}'
            raise RuntimeError(message) from None

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    default_root=Path(os.environ.get('JARVIS_DATA_DIR', Path.home()/'Library/Application Support/Jarvis'))
    parser.add_argument('--session',default=str(default_root/'testing/session.json'))
    sub=parser.add_subparsers(dest='operation',required=True)
    run=sub.add_parser('run');run.add_argument('command');run.add_argument('--mode',choices=['execute','plan','intent','dictation'],default='plan');run.add_argument('--timeout',type=float,default=120)
    sub.add_parser('status');sub.add_parser('list');sub.add_parser('cancel')
    review=sub.add_parser('review');review.add_argument('id');review.add_argument('verdict',choices=['pass','fail','unreviewed']);review.add_argument('--notes',default='')
    export=sub.add_parser('export');export.add_argument('path')
    args=parser.parse_args()
    try:
        client=Client(args.session)
        if args.operation=='run':
            accepted=client.request('/api/run',{'command':args.command,'mode':args.mode})
            deadline=time.monotonic()+args.timeout
            while time.monotonic()<deadline:
                values=client.request('/api/runs');value=next((item for item in values if item['id']==accepted['id']),None)
                if value and value['state']=='finished':
                    print(json.dumps(value,indent=2));return 0 if value['outcome'] in ['success','planned','parsed','formatted'] else 1
                time.sleep(.25)
            client.request('/api/cancel',{});raise RuntimeError('Test timed out; cancellation requested')
        if args.operation=='export':
            value=client.request('/api/export');path=Path(args.path)
            fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
            with os.fdopen(fd,'w') as handle: json.dump(value,handle,indent=2)
            print(f'Saved {len(value)} runs to {path}');return 0
        if args.operation=='review': value=client.request('/api/review',{'id':args.id,'verdict':args.verdict,'notes':args.notes})
        elif args.operation=='cancel': value=client.request('/api/cancel',{})
        else:value=client.request('/api/state' if args.operation=='status' else '/api/runs')
        print(json.dumps(value,indent=2));return 0
    except (OSError, ValueError, RuntimeError) as error:
        print(f'Test runner: {error}. Start it in Jarvis → About → Command testing.',file=sys.stderr);return 2
if __name__=='__main__':sys.exit(main())
