#!/usr/bin/env python3
"""Final realtime screenshots over controlled backgrounds and an actual Finder window."""
import json,re,subprocess,time
from pathlib import Path
from datetime import datetime,timezone
from PIL import Image
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-09-context-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
result={'status':'RUNNING','binary':str(binary),'cases':[]}
for name in ['white','pattern','finder']:
 case=out/name;case.mkdir();procs=[];handles=[];finder_id=None
 def launch(args,log):
  h=log.open('w');handles.append(h);p=subprocess.Popen(args,stdout=h,stderr=subprocess.STDOUT);procs.append(p);return p
 try:
  if name=='finder':
   script='''on run argv
 tell application "Finder"
  set w to make new Finder window to POSIX file (item 1 of argv)
  set bounds of w to {60, 100, 950, 720}
  activate
  return id of w
 end tell
end run'''
   finder_id=int(subprocess.check_output(['osascript','-e',script,str(root)],text=True).strip())
  else:launch([str(fixture),'--large','--background',name,'--duration','15'],case/'fixture.log')
  time.sleep(1)
  app=launch([str(binary),'--test-corner','--duration','8','--output',str(case)],case/'process.log')
  deadline=time.monotonic()+7
  while True:
   p=case/'runtime-latest.json';s=json.loads(p.read_text()) if p.exists() else {}
   if s.get('material_visible') and not s.get('fallback_visible') and s.get('gpu_submissions',0)>0:break
   if app.poll() is not None or time.monotonic()>deadline:raise RuntimeError('No valid realtime material: '+name)
   time.sleep(.1)
  time.sleep(.5)
  ready=json.loads((case/'ready.json').read_text())
  subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'window.png')],check=True)
  x,y,w,h=map(float,re.findall(r'-?[\d.]+',ready['frame_pt']))
  env=json.loads((case/'environment.json').read_text());sx,sy,sw,sh=map(float,re.findall(r'-?[\d.]+',env['screens'][0]['frame_pt']))
  region=f'{int(x-20)},{int(sy+sh-y-h-20)},{int(w+40)},{int(h+40)}'
  subprocess.run(['/usr/sbin/screencapture','-x','-R',region,str(case/'context.png')],check=True)
  im=Image.open(case/'window.png');assert im.size==(824,124)
  assert not s['desktop_blockers'] and not s['pause_reasons']
  result['cases'].append({'name':name,'size':im.size,'runtime':s,'finder_window_id':finder_id})
  print('CAPTURED realtime '+name,flush=True)
 finally:
  for p in procs:
   if p.poll() is None:p.terminate();p.wait(timeout=10)
  for h in handles:h.close()
  if finder_id is not None:subprocess.run(['osascript','-e',f'tell application "Finder" to close Finder window id {finder_id}'],check=True)
result['status']='STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED'
(out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
