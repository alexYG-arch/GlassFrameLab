#!/usr/bin/env python3
"""Real fullscreen Space in a separate native application, with realtime glass."""
import json,math,os,re,subprocess,time
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-08-fullscreen-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
app_out=out/'glass';app_out.mkdir();fixture_out=out/'fixture';fixture_out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve();fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
processes=[];handles=[];states={}
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
def launch(args,path):
 h=path.open('w');handles.append(h);p=subprocess.Popen(args,stdout=h,stderr=subprocess.STDOUT);processes.append(p);return p
try:
 app=launch([str(binary),'--test-corner','--duration','24','--output',str(app_out)],app_out/'process.log')
 time.sleep(2)
 bg=launch([str(fixture),'--fullscreen-probe','--animate','--duration','18','--output',str(fixture_out)],fixture_out/'process.log')
 deadline=time.monotonic()+28
 while bg.poll() is None:
  assert time.monotonic()<deadline,'Fullscreen fixture timeout'
  for stage in ['normal','fullscreen','restored']:
   path=fixture_out/('fixture-'+stage+'.json')
   if path.exists() and stage not in states:
    fixture_state=json.loads(path.read_text())
    time.sleep(.3)
    runtime=json.loads((app_out/'runtime-latest.json').read_text())
    assert not runtime['desktop_blockers'] and not runtime['pause_reasons']
    assert runtime['window_on_active_space'] and runtime['material_visible'] and not runtime['fallback_visible'],(stage,runtime)
    assert runtime['selected_display_id']==runtime['bound_display_id'] and runtime['selected_backing_scale']==runtime['bound_backing_scale']
    ready=json.loads((app_out/'ready.json').read_text());x,y,w,h=map(float,re.findall(r'-?[0-9.]+',runtime['glass_frame_pt']))
    env=json.loads((app_out/'environment.json').read_text());sx,sy,sw,sh=map(float,re.findall(r'-?[0-9.]+',env['screens'][0]['frame_pt']))
    rect=f'{math.floor(x-12)},{math.floor(sy+sh-y-h-12)},{math.ceil(w+24)},{math.ceil(h+24)}'
    subprocess.run(['/usr/sbin/screencapture','-x','-R',rect,str(out/(stage+'.png'))],check=True)
    states[stage]={'fixture':fixture_state,'glass':runtime}
  time.sleep(.1)
 assert bg.returncode==0
 app.wait(timeout=10);assert app.returncode==0
 assert len(states)==3 and states['fullscreen']['fixture']['fullscreen'] and not states['restored']['fixture']['fullscreen']
 assert states['fullscreen']['fixture']['frontmost_bundle']=='local.uidev.GlassFrameFixture'
 result={'status':'PASS','binary':str(binary),'fixture':str(fixture),'states':states,'scope':'Actual separate-app native fullscreen Space entry/exit on the built-in 2x display; not arbitrary desktop Spaces, protected players, external displays or macOS 13'}
except BaseException as error:
 result={'status':'FINDINGS','binary':str(binary),'error':str(error),'states':states};raise
finally:
 for p in processes:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
 for h in handles:h.close()
 if power.poll() is None:power.terminate();power.wait(timeout=5)
 (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
