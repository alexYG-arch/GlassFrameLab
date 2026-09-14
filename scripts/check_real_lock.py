#!/usr/bin/env python3
"""Cooperative actual locked cold start; screenshots only after a stable public unlocked signal."""
import json,os,signal,subprocess,time,sys
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-08-real-lock-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
helper=out/'DesktopState'
cache=root/'.build/clang-cache';cache.mkdir(parents=True,exist_ok=True)
subprocess.run(['swiftc','-module-cache-path',str(cache),str(root/'scripts/window_overlap.swift'),'-o',str(helper)],check=True)
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve();fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
(root/'build/active-lock-verification.txt').write_text(str(out))
processes=[];handles=[];result={};power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
def frontmost():return json.loads(subprocess.check_output([str(helper)],text=True))['frontmost']
def launch(args,path):
 h=path.open('w');handles.append(h);p=subprocess.Popen(args,stdout=h,stderr=subprocess.STDOUT);processes.append(p);return p
try:
 print('WAITING_FOR_LOCK '+str(out),flush=True)
 deadline=time.monotonic()+120
 while frontmost()!='com.apple.loginwindow':
  if time.monotonic()>deadline:raise TimeoutError('No real lock observed')
  time.sleep(.5)
 (out/'lock-observed.json').write_text(json.dumps({'time':time.time(),'frontmost':'com.apple.loginwindow'}))
 launch([str(fixture),'--large','--duration','125'],out/'fixture.log')
 app=launch([str(binary),'--test-corner','--duration','120','--output',str(out/'app')],out/'process.log')
 locked=[];deadline=time.monotonic()+65
 while frontmost()=='com.apple.loginwindow':
  if app.poll() is not None:raise RuntimeError('App exited during locked cold startup')
  p=out/'app/runtime-latest.json'
  if p.exists():
   s=json.loads(p.read_text());locked.append(s)
   assert 'login_window' in s['desktop_blockers'] and s['gpu_submissions']==0 and s['retained_buffers']==0 and s['capture_start_attempts']==0,s
  if time.monotonic()>deadline:raise TimeoutError('Unlock was not observed')
  time.sleep(.5)
 assert len(locked)>=3,'Lock interval too short to verify cold startup'
 (out/'locked-samples.json').write_text(json.dumps(locked,indent=2))
 print('UNLOCK_OBSERVED_WAITING_FOR_VALID_MATERIAL',flush=True)
 deadline=time.monotonic()+40
 while True:
  s=json.loads((out/'app/runtime-latest.json').read_text())
  if not s['desktop_blockers'] and not s['pause_reasons'] and s['state']=='capturing' and s['material_visible'] and not s['fallback_visible'] and s['gpu_submissions']>0:break
  if time.monotonic()>deadline:raise RuntimeError('No valid material after unlock')
  time.sleep(.25)
 (out/'restored.json').write_text(json.dumps(s,indent=2))
 # The user authorized this test; capture only after a stable public unlocked signal.
 for _ in range(4):
  assert frontmost()!='com.apple.loginwindow','Session became locked again'
  time.sleep(.5)
 ready=json.loads((out/'app/ready.json').read_text())
 subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(out/'restored.png')],check=True)
 result={'status':'PASS','binary':str(binary),'actual_locked_cold_start':True,'locked_samples':len(locked),'restored':s,'screenshot_after_stable_public_unlock_signal':True}
except BaseException as error:
 result={'status':'BLOCKED_VERIFICATION' if isinstance(error,TimeoutError) else 'FINDINGS','binary':str(binary),'error':str(error)}
 raise
finally:
 for p in processes+[power]:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
 for h in handles:h.close()
 (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
