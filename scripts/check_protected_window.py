#!/usr/bin/env python3
"""Observe public sharingType.none behavior with our own synthetic window, without workarounds."""
import json,os,subprocess,time
from pathlib import Path
from datetime import datetime,timezone
from PIL import Image,ImageChops,ImageStat
root=Path(__file__).resolve().parents[1];out=root/'docs/evidence'/('WP-08-sharing-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve();fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())]);states={};result={}
try:
 for name,flags in [('normal',[]),('sharing_none',['--protected-window'])]:
  case=out/name;case.mkdir();processes=[]
  with (case/'fixture.log').open('w') as f,(case/'process.log').open('w') as log:
   try:
    bg=subprocess.Popen([str(fixture),'--large','--duration','16',*flags],stdout=f,stderr=subprocess.STDOUT);processes.append(bg)
    time.sleep(1)
    app=subprocess.Popen([str(binary),'--test-corner','--duration','9','--output',str(case/'app')],stdout=log,stderr=subprocess.STDOUT);processes.append(app)
    time.sleep(4)
    ready=json.loads((case/'app/ready.json').read_text());state=json.loads((case/'app/runtime-latest.json').read_text())
    assert not state['desktop_blockers'] and not state['pause_reasons']
    subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'glass.png')],check=True)
    app.wait(timeout=10);assert app.returncode==0
    assert state['gpu_in_flight']<=1 and state['retained_buffers']<=1 and state['intermediate_textures']<=1
    states[name]=state
   finally:
    for p in processes:
     if p.poll() is None:p.terminate();p.wait(timeout=10)
  if name=='sharing_none':assert 'WINDOW_SHARING_TYPE 0' in (case/'fixture.log').read_text()
 with Image.open(out/'normal/glass.png') as a,Image.open(out/'sharing_none/glass.png') as b:
  assert a.size==b.size
  box=(40,30,a.width-40,a.height-30)
  difference=ImageStat.Stat(ImageChops.difference(a.convert('RGB').crop(box),b.convert('RGB').crop(box))).mean
  mean_difference=sum(difference)/3
 unchanged=mean_difference<1
 result={'status':'OBSERVATION_ONLY','stability_check':'PASS','binary':str(binary),'fixture':str(fixture),'states':states,
  'sharing_none_property_verified':True,'mean_absolute_rgb_difference':mean_difference,'captured_material_unchanged':unchanged,
  'protected_content_acceptance':'BLOCKED_VERIFICATION',
  'scope':'Public sharingType.none on an owned synthetic window; unchanged output means this fixture did not establish protected-content behavior. No DRM content, bypass, filter workaround or protection override was used.'}
except BaseException as error:result={'status':'FINDINGS','error':str(error),'states':states};raise
finally:
 if power.poll() is None:power.terminate();power.wait(timeout=5)
 (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
