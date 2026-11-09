#!/usr/bin/env python3
"""Exact signed-bundle comparison; read-only intent/planning, no Execute mode.
Fresh LaunchServices launches, isolated data, uncached inference, alternating order.
macOS libproc samples app RSS/footprint/CPU; no microphone or external actions.
"""
import ctypes as C
import importlib.util,json,os,subprocess,tempfile,time,threading,statistics,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('runtime_bench',ROOT/'scripts/benchmark_runtime.py');bench=importlib.util.module_from_spec(spec);spec.loader.exec_module(bench)
FIELDS=['user','system','pkg_wake','interrupt_wake','pageins','wired','rss','footprint','start','exit','child_user','child_system','child_pkg','child_interrupt','child_pageins','child_elapsed','disk_read','disk_write','qos_default','qos_maintenance','qos_background','qos_utility','qos_legacy','qos_initiated','qos_interactive','billed_system','serviced_system','logical_write','peak_footprint','instructions','cycles','billed_energy','serviced_energy','interval_peak','runnable']
class Usage(C.Structure):_fields_=[('uuid',C.c_ubyte*16)]+[(n,C.c_uint64) for n in FIELDS]
class Timebase(C.Structure):_fields_=[('numer',C.c_uint32),('denom',C.c_uint32)]
tb=Timebase();C.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(C.byref(tb));CPU_NS_PER_TICK=tb.numer/tb.denom
lib=C.CDLL('/usr/lib/libproc.dylib');lib.proc_pid_rusage.argtypes=[C.c_int,C.c_int,C.c_void_p]
def usage(pid):
 u=Usage()
 if lib.proc_pid_rusage(pid,4,C.byref(u)):raise ProcessLookupError(pid)
 return dict(rss=u.rss,footprint=u.footprint,peak_footprint=u.peak_footprint,cpu_ns=int((u.user+u.system)*CPU_NS_PER_TICK))
class Sample:
 def __init__(self,pid):self.pid=pid;self.rows=[];self.phase='startup';self.done=False;self.thread=threading.Thread(target=self.work,daemon=True);self.thread.start()
 def work(self):
  while not self.done:
   try:self.rows.append(dict(t=time.monotonic(),phase=self.phase,**usage(self.pid)))
   except ProcessLookupError:break
   time.sleep(.02)
 def stage(self,name,operation):
  self.phase=name;a=usage(self.pid);t=time.monotonic();value=operation();elapsed=time.monotonic()-t;b=usage(self.pid)
  return dict(wall_s=elapsed,cpu_s=(b['cpu_ns']-a['cpu_ns'])/1e9,cpu_percent=(b['cpu_ns']-a['cpu_ns'])/1e9/elapsed*100,**b),value
 def finish(self):self.done=True;self.thread.join()
def launch(app,data):
 subprocess.run(['open','-n','-F','--env',f'JARVIS_DATA_DIR={data}','--env','JARVIS_INTENT_CACHE=0','--env','JARVIS_RUST_PIPELINE=1',str(app),'--args','--test-mode'],check=True)
 f=data/'testing/session.json'
 for _ in range(450):
  if f.exists():return json.loads(f.read_text())['pid'],bench.Runner(f)
  time.sleep(.1)
 raise RuntimeError(f'No endpoint: {data}')
def identity(app):
 return dict(path=str(app),uuid=subprocess.check_output(['xcrun','dwarfdump','--uuid',str(app/'Contents/MacOS/Jarvis')],text=True).split()[1],bytes=bench.inventory(app)['bytes'],binary_sha256=hashlib.sha256((app/'Contents/MacOS/Jarvis').read_bytes()).hexdigest())
def run(app,label,round_no,retained):
 data=Path(tempfile.mkdtemp(prefix=f'jarvis-ab-{label}-'));pid,runner=launch(app,data);sampler=Sample(pid)
 print(label,round_no,'started',pid,flush=True)
 completed=False
 try:
  time.sleep(10) # model-file verification/startup settles before the idle window
  idle,_=sampler.stage('idle_unloaded',lambda:time.sleep(5))
  cold,first=sampler.stage('intent_cold',lambda:runner.run('open chrome','intent'))
  warm=[]
  for text in bench.INTENT_COMMANDS:runner.run(text,'intent')
  def infer():
   for repeat in range(5):
    for text in bench.INTENT_COMMANDS:warm.append(runner.run(text,'intent'))
  active,_=sampler.stage('intent_warm',infer)
  loaded,_=sampler.stage('idle_loaded',lambda:time.sleep(5))
  plans=[]
  def planning():
   for repeat in range(3):
    for text in bench.INTENT_COMMANDS:plans.append(runner.run(text,'plan'))
  plan,_=sampler.stage('planning',planning)
  result=dict(label=label,round=round_no,pid=pid,data_dir=str(data),idle=idle,cold=cold,cold_run=first,active=active,loaded=loaded,planning=plan,intent=warm,plans=plans)
  sampler.finish();result['samples']=sampler.rows
  completed=True
  if retained:
   result['retained']=True;return result,(pid,runner,data)
  return result,None
 finally:
  sampler.finish()
  if not retained or not completed:
   try:os.kill(pid,15)
   except ProcessLookupError:pass

def main():
 out=ROOT/'logs/release-comparison-20261109';out.mkdir(parents=True,exist_ok=True)
 apps={'installed':Path('/Applications/Jarvis.app'),'candidate':ROOT/'.build/Jarvis.app'}
 result=dict(cpu_unit_conversion=dict(original='normalized during capture',numer=tb.numer,denom=tb.denom,normalized='nanoseconds'),identities={k:identity(v) for k,v in apps.items()},rounds=[],retained=[],method='Fresh LaunchServices -F; same isolated setup; cache off; three launches/build; 12 commands x5 intent rounds + x3 planning rounds; libproc every20ms; CPU100%=one core.')
 held=[]
 try:
  for i,order in enumerate([['installed','candidate'],['candidate','installed'],['installed','candidate']]):
   for label in order:
    row,handle=run(apps[label],label,i+1,i==2);result['rounds'].append(row)
    if handle:held.append((label,handle))
    (out/'raw.json').write_text(json.dumps(result,indent=2)+'\n')
  # Measure automatic unload separately; no extra model requests reset its timer.
  print('Waiting for idle unload; retained final processes only.',flush=True)
  deadline=time.monotonic()+155
  while time.monotonic()<deadline:
   result['retained'].append(dict(t=time.monotonic(),processes={k:usage(v[0]) for k,v in held}));time.sleep(1)
  for label,(pid,runner,data) in held:
   after=usage(pid);start=time.monotonic();reloaded=runner.run('open chrome','intent')
   result.setdefault('reload',{})[label]=dict(after_idle=after,reload_wall_ms=(time.monotonic()-start)*1000,run=reloaded)
  (out/'raw.json').write_text(json.dumps(result,indent=2)+'\n')
  print('Complete',out,flush=True)
 finally:
  for _,(pid,_,_) in held:
   try:os.kill(pid,15)
   except ProcessLookupError:pass
if __name__=='__main__':main()
