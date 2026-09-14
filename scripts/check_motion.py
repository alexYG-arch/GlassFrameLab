#!/usr/bin/env python3
"""Native motion, interruption and style invalidation checks; screenshots are diagnostic."""
import json,subprocess,time,csv,os,re
from PIL import Image
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-07-motion-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
with (out/'fixture.log').open('w') as f,(out/'process.log').open('w') as log:
 background=subprocess.Popen([str(fixture),'--large','--duration','25'],stdout=f,stderr=subprocess.STDOUT)
 try:
  time.sleep(1)
  app=subprocess.Popen([str(binary),'--test-corner','--motion-probe','--duration','14','--output',str(out)],stdout=log,stderr=subprocess.STDOUT,env={**os.environ,"GLASS_RASTER_DIAGNOSTICS":"1"})
  try:
   started=time.monotonic()
   for _ in range(100):
    if (out/'ready.json').exists():break
    time.sleep(.05)
   ready=json.loads((out/'ready.json').read_text());captures=[]
   started=ready['measurement_start_uptime']
   assert abs(time.monotonic()-started)<10, 'Host and application monotonic clocks must match'
   for target in [1.5,2.05,2.2,3.05,3.15,3.3,3.45,3.6,3.85,4.55,4.7,4.9,5.55,5.75,6.15,6.3,6.5,7.2,7.45,8.2,8.7,11.5]:
    time.sleep(max(0,started+target-time.monotonic()))
    path=out/f'window-{target:.2f}.png'
    result=subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(path)],capture_output=True)
    captures.append({'target_seconds':target,'actual_seconds':time.monotonic()-started,'file':path.name,'exit':result.returncode})
    if app.poll() is not None:break
   app.wait(timeout=20)
   (out/'screenshots.json').write_text(json.dumps(captures,indent=2))
   assert app.returncode==0,(out/'process.log').read_text()
  finally:
   if app.poll() is None:app.terminate();app.wait(timeout=10)
 finally:
  if background.poll() is None:background.terminate();background.wait(timeout=10)
raster_lines=(out/'process.log').read_text().splitlines()
rasters=[json.loads(line[7:]) for line in raster_lines if line.startswith('RASTER ')]
assert rasters, 'Missing actual drawable diagnostics'
assert not any(line.startswith('GEOMETRY_MISMATCH') for line in raster_lines), 'Presentation frame differs from committed window'
for raster in rasters:
 requested=[round(float(x)) for x in re.findall(r'[0-9.]+',raster['requested'])]
 actual=[int(x) for x in raster['texture'].split('x')]
 assert requested==actual and raster['contents_scale']==raster['backing_scale'],raster
for screenshot in captures:
 assert screenshot['exit']==0,screenshot
 with Image.open(out/screenshot['file']) as im:
  alpha=im.convert('RGBA').getchannel('A')
  assert sum(alpha.histogram()[128:])>im.width*im.height*.5, 'Missing glass body in '+screenshot['file']
(out/'raster-check.json').write_text(json.dumps({'status':'PASS','frames_checked':len(rasters),
 'screenshots_with_visible_body':len(captures),'geometry_mismatches':0},indent=2))
assert not (out/'runtime-error.json').exists()
geometries=[json.loads(p.read_text()) for p in sorted(out.glob('geometry-*.json'))]
assert 15<len(geometries)<90,len(geometries)
assert geometries[-1]['actual_size_px']=='{800, 100}',geometries[-1]
assert any(g['actual_size_px']=='{1200, 180}' and 10<g['elapsed_seconds']<10.6 for g in geometries),'Plain resize request did not commit'
state=json.loads((out/'motion-settled.json').read_text())
assert state['capture_envelope_pt']=='none' and not state['geometry_motion_active']
assert state['rendered_glass_frame_pt']==state['glass_frame_pt'] and state['material_visible'],state
assert state['style_revision']==state['rendered_style_revision']==2,state
assert state['intermediate_textures']==1 and state['gpu_in_flight']==0
samples=list(csv.DictReader((out/'runtime-samples.csv').open()));last=[x for x in samples if float(x['elapsed_seconds'])>=11]
assert len(last)>=2 and len({x['submitted'] for x in last})==1,last
assert all(int(x['in_flight'])<=1 and int(x['retained_buffers'])<=1 for x in samples)
(out/'result.json').write_text(json.dumps({'status':'STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED','binary':str(binary),'fixture':str(fixture),'geometry_commits':len(geometries),'final':state,'screenshots':'screenshots.json'},indent=2))
print(out,flush=True)
