#!/usr/bin/env python3
"""Read-only external snapshots around input changes; diagnostic, not a budget run."""
import json,subprocess,time,re,os
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-06-input-diagnosis-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
out.mkdir(); processes=[]; handles=[]
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
def launch(args,path):
 h=path.open('w');handles.append(h);p=subprocess.Popen(args,stdout=h,stderr=subprocess.STDOUT);processes.append(p);return p
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
try:
 launch([str(fixture),'--test-corner','--duration','345'],out/'fixture.log');time.sleep(1)
 case=out/'glass';case.mkdir();base=out/'baseline';base.mkdir()
 app=launch([str(binary),'--test-corner','--duration','331','--output',str(case)],out/'process.log')
 launch([str(binary),'--baseline','--duration','331','--output',str(base)],out/'baseline.log')
 start=time.monotonic();last=None;next_snapshot=10;index=0;events=[]
 while app.poll() is None:
  elapsed=time.monotonic()-start
  if elapsed>350:raise RuntimeError('Diagnostic timeout')
  path=case/'runtime-latest.json'
  if path.exists():
   state=json.loads(path.read_text());count=state['gpu_submissions']
   changed=last is not None and count!=last
   if changed or elapsed>=next_snapshot:
    snapshot=out/f'snapshot-{index:03d}';snapshot.mkdir();index+=1
    reason='input_changed' if changed else 'periodic'
    ready=json.loads((case/'ready.json').read_text())
    fixture_id=re.search(r'fixture=(\d+)',(out/'fixture.log').read_text()).group(1)
    for name,args in [('region',['-R64,157,472,122']),('fixture',['-l',fixture_id]),('glass',['-l',str(ready['window_number'])])]:
     subprocess.run(['/usr/sbin/screencapture','-x','-o',*args,str(snapshot/(name+'.png'))],check=True)
    windows=subprocess.check_output([str(root/'build/WindowOverlapDiagnostic')])
    (snapshot/'windows.json').write_bytes(windows)
    event={'elapsed':elapsed,'reason':reason,'runtime':state,'snapshot':str(snapshot)}
    (snapshot/'event.json').write_text(json.dumps(event,indent=2));events.append(event)
    print(f'{reason}: {elapsed:.1f}s submitted={count}',flush=True)
    next_snapshot=float("inf")
   last=count
  time.sleep(.2)
 assert app.returncode==0
 (out/'result.json').write_text(json.dumps({'status':'DIAGNOSTIC_ONLY','binary':str(binary),'fixture':str(fixture),'events':events,'note':'Screenshot and window inspection processes make this unsuitable for formal CPU/latency budgets.'},indent=2))
finally:
 for p in processes:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
 for h in handles:h.close()
 if power.poll() is None:power.terminate();power.wait(timeout=5)
print(out,flush=True)
