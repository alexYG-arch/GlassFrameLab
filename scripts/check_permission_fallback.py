#!/usr/bin/env python3
"""Try real TCC denial with a disposable app identity; never revoke existing grants."""
import json,math,os,plistlib,re,shutil,signal,subprocess,tempfile,time
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1];stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
out=root/'docs/evidence'/('WP-08-permission-'+stamp);out.mkdir()
source=(root/'build/GlassFrameLab.app').resolve();holder=Path(tempfile.mkdtemp(prefix='glassframe-permission-',dir='/private/tmp'));app=holder/'GlassFramePermissionCheck.app'
shutil.copytree(source,app)
info=app/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());identity='local.uidev.GlassFrameLab.PermissionCheck.'+stamp.lower();data['CFBundleIdentifier']=identity;info.write_bytes(plistlib.dumps(data))
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
subprocess.run(['/usr/bin/codesign','--verify','--strict',str(app)],check=True,capture_output=True)
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())]);background=None;launcher=None;pid=None;result={}
try:
 with (out/'fixture.log').open('w') as f,(out/'launch.log').open('w') as log:
  background=subprocess.Popen([str(fixture),'--large','--duration','22'],stdout=f,stderr=subprocess.STDOUT)
  time.sleep(1)
  launcher=subprocess.Popen(['/usr/bin/open','-n','-W',str(app),'--args','--test-corner','--duration','12','--output',str(out/'app')],stdout=log,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+10
  while not (out/'app/runtime-latest.json').exists():
   assert time.monotonic()<deadline,'Isolated app did not produce runtime evidence';time.sleep(.1)
  time.sleep(3)
  env=json.loads((out/'app/environment.json').read_text());pid=env['process_id']
  state=json.loads((out/'app/runtime-latest.json').read_text());ready=json.loads((out/'app/ready.json').read_text())
  subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(out/'window.png')],check=True)
  x,y,w,h=map(float,re.findall(r'-?[0-9.]+',ready['frame_pt']))
  sx,sy,sw,sh=map(float,re.findall(r'-?[0-9.]+',env['screens'][0]['frame_pt']))
  rect=f'{math.floor(x-8)},{math.floor(sy+sh-y-h-8)},{math.ceil(w+16)},{math.ceil(h+16)}'
  subprocess.run(['/usr/sbin/screencapture','-x','-R',rect,str(out/'composite.png')],check=True)
  launcher.wait(timeout=15);assert launcher.returncode==0
  denied=state['state']=='permission_required' and state['permission_check_source']=='system_preflight'
  if denied:assert state['fallback_visible'] and not state['material_visible'] and state['gpu_submissions']==0 and state['retained_buffers']==0
  result={'status':'PASS' if denied else 'BLOCKED_VERIFICATION','condition':'real_ungranted_app_identity' if denied else 'isolated_identity_did_not_reproduce_os_denial',
   'identity':identity,'source_app':str(source),'test_app':str(app),'state':state,'scope':'System preflight on a separately signed disposable identity; existing permissions unchanged; no injected denial flag'}
except BaseException as error:
 result={'status':'FINDINGS','error':str(error),'identity':identity};raise
finally:
 if pid:
  command=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout.strip()
  if command.startswith(str(app/'Contents/MacOS/GlassFrameLab')):
   try:os.kill(pid,signal.SIGTERM)
   except ProcessLookupError:pass
 for p in [launcher,background,power]:
  if p is not None and p.poll() is None:p.terminate();p.wait(timeout=10)
 (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
