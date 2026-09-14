#!/usr/bin/env python3
"""Native fallback/recovery integration. Injected conditions are not environment acceptance."""
import csv,json,math,re,statistics,subprocess,time,sys
from pathlib import Path
from datetime import datetime,timezone
from PIL import Image
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-08-compat-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(__import__('os').getpid())])
assert sys.argv[1:] in [[],['--static']]
static='--static' in sys.argv
results={}
try:
 for case_name in ['denied','interruptions']:
  case=out/case_name;case.mkdir();seen=set()
  with (case/'fixture.log').open('w') as f,(case/'process.log').open('w') as log:
   background=subprocess.Popen([str(fixture),'--large',*([] if static else ['--animate']),'--duration','45'],stdout=f,stderr=subprocess.STDOUT)
   app=None
   try:
    time.sleep(1)
    app=subprocess.Popen([str(binary),'--test-corner','--compatibility-probe','--duration','32','--output',str(case),*(['--test-permission-denied'] if case_name=='denied' else [])],stdout=log,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+40
    while app.poll() is None:
     assert time.monotonic()<deadline,'Compatibility probe timeout'
     for p in sorted(case.glob('compat-*.json')):
      s=json.loads(p.read_text());stage=s['probe_stage']
      if stage in seen or stage in ['hidden','context_menu_close']:continue
      assert not s['desktop_blockers'] and not s['pause_reasons'],'Desktop unavailable; not a valid injected test'
      subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(s['window_number']),str(case/(stage+'.png'))],check=True)
      if stage in ['initial','unavailable','fallback_geometry','final']:
       x,y,w,h=map(float,re.findall(r'-?[0-9.]+',s['frame_pt']))
       env=json.loads((case/'environment.json').read_text());sx,sy,sw,sh=map(float,re.findall(r'-?[0-9.]+',env['screens'][0]['frame_pt']))
       rect=f'{math.floor(x-8)},{math.floor(sy+sh-y-h-8)},{math.ceil(w+16)},{math.ceil(h+16)}'
       subprocess.run(['/usr/sbin/screencapture','-x','-R',rect,str(case/(stage+'-composite.png'))],check=True)
      seen.add(stage)
     time.sleep(.1)
    assert app.returncode==0
   finally:
    for process in [app,background]:
     if process is not None and process.poll() is None:process.terminate();process.wait(timeout=10)
  states={p.stem.removeprefix('compat-'):json.loads(p.read_text()) for p in case.glob('compat-*.json')}
  assert len(states)==15,states.keys()
  assert 'context_menu_close' in states and (case/'termination.json').exists()
  assert states['hidden']['retained_buffers']==0 and states['hidden']['gpu_in_flight']==0 and not states['hidden']['window_visible']
  if case_name=='denied':
   assert all(s['gpu_submissions']==0 and s['retained_buffers']==0 for s in states.values())
   assert all(s['fallback_visible'] and not s['material_visible'] for n,s in states.items() if n!='hidden')
   assert states['final']['capture_start_attempts']<=3,'Permission denial is being retried repeatedly'
   assert states['initial']['permission_check_source']=='injected_denial'
  else:
   for n in ['unavailable','fallback_geometry','suspended','stopped','stream_failed']:
    s=states[n];assert s['fallback_visible'] and not s['material_visible'] and s['retained_buffers']==0,(n,s)
   for n in ['initial','recovered_blank','recovered_suspended','recovered_stopped','recovered_stream','recovered_rebind','final']:
    s=states[n]
    # Clearing an injected status cannot manufacture pixels. On a static source,
    # ScreenCaptureKit may emit idle (no buffer) until an actual complete frame.
    if static and n in ['recovered_blank','recovered_suspended','recovered_stopped'] and s['retained_buffers']==0:
     assert s['fallback_visible'] and not s['material_visible'] and s['unavailable_frame_reason'] in ['blank','suspended','stopped'],(n,s)
    else:
     assert s['material_visible'] and not s['fallback_visible'] and s['state']=='capturing',(n,s)
   assert states['final']['capture_start_attempts']<=5,'Unbounded recovery attempts'
   assert states['final']['stale_geometry_frames']>=1,'Delayed geometry sample was not rejected'
   assert states['final']['rendered_glass_frame_pt']==states['final']['glass_frame_pt'],'Deferred geometry did not resume'
  def rect(s):return list(map(float,re.findall(r'-?[0-9.]+',s['frame_pt'])))
  before=rect(states['drag_requested']);after=rect(states['fallback_geometry'])
  assert abs(after[0]-before[0]-60)<=1 and abs(after[1]-before[1]+20)<=1,'Fallback drag did not preserve its requested displacement'
  assert after[2:]==[612,102],after
  assert rect(states['final'])[2:]==[412,62]
  for image_path in case.glob('*.png'):
   with Image.open(image_path) as image:
    histogram=image.convert('RGBA').getchannel('A').histogram()
    assert sum(histogram[40:])>image.width*image.height*.5,'Empty fallback screenshot: '+str(image_path)
  samples=list(csv.DictReader((case/'samples.csv').open()))
  cpu=statistics.median(float(s['cpu_percent_one_core']) for s in samples if 7<=float(s['elapsed_seconds'])<23)
  results[case_name]={'status':'PASS','injected':True,'cpu_diagnostic_median_percent':cpu,'scope':'Native fallback geometry, responder drag, context-menu action, sample invalidation, bounded recovery; not real TCC/protected-content/cross-display acceptance','states':states}
  print('PASS '+case_name,flush=True)
 (out/'result.json').write_text(json.dumps({'status':'PASS','binary':str(binary),'fixture':str(fixture),'background':'static' if static else 'animated','delayed_geometry_injection_ms':350,'cases':results},indent=2))
except BaseException as error:
 (out/'result.json').write_text(json.dumps({'status':'FINDINGS','binary':str(binary),'error':str(error),'completed_cases':results},indent=2))
 raise
finally:
 if power.poll() is None:power.terminate();power.wait(timeout=5)
 print(out,flush=True)
