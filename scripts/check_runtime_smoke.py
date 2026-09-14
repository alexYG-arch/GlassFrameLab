#!/usr/bin/env python3
import csv,json,subprocess,time,sys
from PIL import Image
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1]
output=root/'docs/evidence'/('WP-06-runtime-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
output.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
large = sys.argv[1:] == ['--large']
assert not sys.argv[1:] or large, 'Usage: check_runtime_smoke.py [--large]'
scenes = [('cycles',['--runtime-probe'],109)] if large else [('static',[],40),('cycles',['--runtime-probe'],109)]
for name,args,duration in scenes:
 case=output/name;case.mkdir()
 with (case/'fixture.log').open('w') as f,(case/'process.log').open('w') as log:
  background=subprocess.Popen([str(fixture),'--large' if large else '--test-corner','--duration',str(duration+10)],stdout=f,stderr=subprocess.STDOUT)
  try:
   time.sleep(1)
   process=subprocess.Popen([str(binary),*(['--width-px','10000','--height-px','10000'] if large else ['--test-corner']),'--duration',str(duration),'--output',str(case),*args],stdout=log,stderr=subprocess.STDOUT)
   try:
    time.sleep(5)
    ready=json.loads((case/'ready.json').read_text())
    subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'window.png')],check=True)
    if name=='cycles':
     for index in range(20):
      target=ready['measurement_start_uptime']+57.65+index*2
      time.sleep(max(0,target-time.monotonic()))
      shot=case/f'restore-{index+1:02d}.png'
      subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(shot)],check=True)
      with Image.open(shot) as image:
       alpha=image.convert('RGBA').getchannel('A')
       assert sum(alpha.histogram()[240:])>image.width*image.height*.6,'Restored material was not visible: '+shot.name
    process.wait(timeout=duration+20)
    assert process.returncode==0
   finally:
    if process.poll() is None: process.terminate();process.wait(timeout=10)
  finally:
   if background.poll() is None: background.terminate();background.wait(timeout=10)
 states=list(csv.DictReader((case/'runtime-samples.csv').open()))
 assert all(int(r['in_flight'])<=1 and int(r['retained_buffers'])<=1 for r in states)
 if name=='static':
  settled=[r for r in states if float(r['elapsed_seconds'])>=30]
  assert len({r['submitted'] for r in settled})==1, settled
  assert all(r['target_fps']=='15' for r in settled)
 else:
  paused=json.loads((case/'runtime-nested-pause.json').read_text());resumed=json.loads((case/'runtime-resumed.json').read_text())
  assert paused['pause_reasons']==['session'] and paused['state']=='stopped' and paused['gpu_in_flight']==0
  assert resumed['pause_reasons']==[] and resumed['state']=='capturing' and resumed['gpu_submissions']>paused['gpu_submissions']
  before=json.loads((case/'runtime-hidden-baseline.json').read_text());after=json.loads((case/'runtime-hidden-final.json').read_text())
  assert after['resident_bytes']-before['resident_bytes']<=10*1024*1024,(before,after)
  assert after['gpu_in_flight']==0 and after['retained_buffers']==0 and after['state']=='stopped'
  assert after['gpu_submissions']-before['gpu_submissions']>=20,'Each of the twenty restorations must render a fresh frame'
  frames=list(csv.DictReader((case/'frames.csv').open()))
  start=json.loads((case/'ready.json').read_text())['measurement_start_uptime']
  shown=[float(f['presented_seconds'])-start for f in frames if float(f['presented_seconds'])>0]
  restoration_presentations=[sum(57+2*i<=t<58+2*i for t in shown) for i in range(20)]
  (case/'restoration-presentations.json').write_text(json.dumps({'counts':restoration_presentations},indent=2))
  # A first drawable revealed from opacity zero can have no presentedTime even
  # though its pixels are visible. Each restore is checked above by native screenshot;
  # zero timestamps remain excluded from all FPS/latency measurements.

  assert after['dropped_metric_records']==0
  last=[r for r in states if float(r['elapsed_seconds'])>=98]
  assert len({r['submitted'] for r in last})==1 and len({r['captured'] for r in last})==1,last
 (case/'result.json').write_text(json.dumps({'status':'PASS','kind':name,'size':'maximum' if large else 'default','actual_size_px':ready['content_size_px'],'binary':str(binary),'fixture':str(fixture)},indent=2))
 print(f'PASS {name}: {case}',flush=True)
print(output,flush=True)
