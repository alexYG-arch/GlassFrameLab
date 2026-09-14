#!/usr/bin/env python3
"""Native initialization-failure fallback; explicitly injected, not hardware absence."""
import json,math,os,re,subprocess,time
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1];out=root/'docs/evidence'/('WP-08-no-metal-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve();fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())]);processes=[];result={}
try:
 with (out/'fixture.log').open('w') as f,(out/'process.log').open('w') as log:
  bg=subprocess.Popen([str(fixture),'--large','--duration','16'],stdout=f,stderr=subprocess.STDOUT);processes.append(bg)
  time.sleep(1)
  app=subprocess.Popen([str(binary),'--test-corner','--test-metal-unavailable','--duration','10','--output',str(out/'app')],stdout=log,stderr=subprocess.STDOUT);processes.append(app)
  time.sleep(4)
  error=json.loads((out/'app/runtime-error.json').read_text());assert error['state']=='native_fallback' and error['fallback_visible'] and error['injected_metal_failure']
  ready=json.loads((out/'app/ready.json').read_text());env=json.loads((out/'app/environment.json').read_text())
  x,y,w,h=map(float,re.findall(r'-?[0-9.]+',ready['frame_pt']));sx,sy,sw,sh=map(float,re.findall(r'-?[0-9.]+',env['screens'][0]['frame_pt']))
  rect=f'{math.floor(x-8)},{math.floor(sy+sh-y-h-8)},{math.ceil(w+16)},{math.ceil(h+16)}'
  subprocess.run(['/usr/sbin/screencapture','-x','-R',rect,str(out/'composite.png')],check=True)
  app.wait(timeout=12);assert app.returncode==0
  assert not (out/'app/runtime-latest.json').exists(),'A renderer was unexpectedly created'
  result={'status':'PASS','binary':str(binary),'injected':True,'error':error,'scope':'Native fallback after simulated renderer initialization failure; not a claim of unavailable physical Metal hardware'}
except BaseException as error:result={'status':'FINDINGS','error':str(error),'binary':str(binary)};raise
finally:
 for p in processes+[power]:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
 (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
