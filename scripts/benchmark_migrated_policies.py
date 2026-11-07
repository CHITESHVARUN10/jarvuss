#!/usr/bin/env python3
"""Run opt-in pure-policy timings against reconstructed installed-era Swift source.

Requires Git history and the native bridges. Generates a temporary XCTest file,
runs it in the selected build configuration, and removes it even on test failure.
It does not launch applications, execute commands, or modify stored settings.
"""
from pathlib import Path
import subprocess,re,json
import argparse,os,shlex
parser=argparse.ArgumentParser(description="Benchmark migrated pure policies against reconstructed baseline source; no application actions.")
parser.add_argument('--baseline',default='125a9eb')
parser.add_argument('--configuration',choices=['debug','release'],default='release')
parser.add_argument('--output',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
out=root/'.build/migration-benchmark';out.mkdir(parents=True,exist_ok=True)
rev=args.baseline
def source(path):return subprocess.check_output(['git','show',rev+':'+path],cwd=root,text=True)
paths={'SystemVolumeParser':'Sources/JarvisMacOS/Commands/SystemVolumeParser.swift','LocalSearchParser':'Sources/JarvisMacOS/Files/LocalSearchParser.swift','SpotifyShuffleParser':'Sources/JarvisMacOS/Commands/SpotifyShuffleParser.swift','TranscriptSanitizer':'Sources/JarvisMacOS/App/TranscriptSanitizer.swift','FastPathRouter':'Sources/JarvisMacOS/Commands/FastPathRouter.swift','CommandValidator':'Sources/JarvisMacOS/Commands/CommandValidator.swift'}
texts=[source(p) for p in paths.values()]
workspace=source('Sources/JarvisMacOS/Workspace/WorkspaceCommand.swift')
a=workspace.index('    static func parse(_ text: String) -> Self?');b=workspace.index('\n}\n\nstruct WorkspaceCommand',a)
texts.append('import Foundation\nenum InstalledWorkspaceAppPolicy {\n'+workspace[a:b].replace('-> Self?', '-> WorkspaceApp?')+'\n}\n'+workspace[workspace.index('enum WorkspaceCommandParser {'):])
store=source('Sources/JarvisMacOS/App/AutomationStore.swift');texts.append(store[:store.index('struct VoiceAutomation:')])
controller=source('Sources/JarvisMacOS/System/AppController.swift');texts.append(controller[controller.index('enum AppAliasResolver {'):])
renames={k:'Installed'+k for k in [*paths,'WorkspaceCommandParser','AppAliasResolver','AutomationActionType','AutomationAction']}
renamed=[]
for text in texts:
 text=text.replace('WorkspaceApp.parse(', 'InstalledWorkspaceAppPolicy.parse(')
 for old,new in renames.items():text=re.sub(r'\b'+old+r'\b',new,text)
 renamed.append(text)
legacy='import Foundation\n'+ '\n'.join(renamed)
# The same post-migration Swift model types are used for both policies; native
# adapters are never invoked. Only unchanged format/enum contracts are shared.
(out/'InstalledPolicies.snapshot.swift').write_text(legacy)
fixture=root/'Tests/JarvisMacOSTests/InstalledPolicyBenchmark.generated.swift'
if fixture.exists():raise SystemExit('Refuse to overwrite another benchmark fixture')
fixture.write_text('import XCTest\n@testable import JarvisMacOS\n'+legacy+'\n'+(root/'scripts/benchmarks/PolicyBenchmarkBody.swift').read_text())
(out/'baseline-source.json').write_text(json.dumps({'commit':subprocess.check_output(['git','rev-parse',rev],cwd=root,text=True).strip(),'policy_paths':list(paths.values())+['Sources/JarvisMacOS/Workspace/WorkspaceCommand.swift','Sources/JarvisMacOS/App/AutomationStore.swift','Sources/JarvisMacOS/System/AppController.swift'],'provenance_note':'Installed build is marked modified at 74485e7; the routines changes were subsequently committed as 125a9eb. The real installed binary is benchmarked separately; this is a reconstruction of its policy source, not proof of a byte-identical rebuild.'},indent=2)+'\n')
print('Generated installed-era policy benchmark fixture.')

output=(args.output or out/('policy-'+args.configuration+'.json')).resolve()
output.parent.mkdir(parents=True,exist_ok=True)
log=out/('policy-'+args.configuration+'-run.log')
env=dict(os.environ,JARVIS_POLICY_BENCH_OUTPUT=str(output),JARVIS_POLICY_BENCH_CONFIGURATION=args.configuration)
try:
    command='source '+shlex.quote(str(root/'scripts/macos_toolchain.zsh'))+'\nswift test -c '+args.configuration+' --filter InstalledPolicyBenchmark'
    with log.open('w') as handle:
        result=subprocess.run(['zsh','-c',command],cwd=root,env=env,stdout=handle,stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit('Benchmark failed; see '+str(log))
    print('Results:',output)
    print('Build/test log:',log)
finally:
    fixture.unlink(missing_ok=True)
