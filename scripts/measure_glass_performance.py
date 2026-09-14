#!/usr/bin/env python3
"""Frozen-build measurements: 30 seconds warm-up, then 300 seconds per scene."""
import json,subprocess,time,sys,os
from datetime import datetime,timezone
from pathlib import Path
root=Path(__file__).resolve().parents[1]
output=root/'docs/evidence'/('WP-06-performance-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
output.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
static_only = len(sys.argv)==3 and sys.argv[2]=='--static-only'
core_only = len(sys.argv)==3 and sys.argv[2]=='--core-only'
large_first = len(sys.argv)==3 and sys.argv[2]=='--large-first'
if len(sys.argv)!=2 and not (static_only or core_only or large_first): raise SystemExit('Usage: measure_glass_performance.py PATH_TO_SUCCESSFUL_CYCLES_EVIDENCE [--static-only | --core-only | --large-first]')
cycles=Path(sys.argv[1]).resolve()
cycle_result=json.loads((cycles/'result.json').read_text())
assert cycle_result['status']=='PASS' and cycle_result['binary']==str(binary) and cycle_result['fixture']==str(fixture),'Cycle evidence must match the current fixed build'
(output/'run.json').write_text(json.dumps({'scope':'static_only' if static_only else ('core_three_scenes' if core_only else 'full_four_scenes'),'binary':str(binary),'fixture':str(fixture),'warmup_seconds':30,'measurement_seconds':300,'large_first':large_first,'static_dynamic_location':'explicit test-corner, full 472x122 sampling region on the measured 2x display','baseline':'concurrent no-window process during static scene','power_assertion':'Temporary display/system idle-sleep assertion bound to this measurement process; no persistent settings changed. Manual lock aborts the run.'},indent=2))

def scene(name,large=False,animated=False,baseline=False,flags=None):
 case=output/name;case.mkdir()
 processes=[];handles=[]
 def launch(args,log):
  handle=log.open('w');handles.append(handle)
  p=subprocess.Popen(args,stdout=handle,stderr=subprocess.STDOUT);processes.append(p);return p
 try:
  background=launch([str(fixture),'--duration','350',*(['--large'] if large else ['--test-corner']),*(['--animate'] if animated else [])],case/'fixture.log')
  time.sleep(1)
  glass=launch([str(binary),'--duration','331','--output',str(case),*(['--width-px','10000','--height-px','10000'] if large else ['--test-corner']),*(flags or [])],case/'process.log')
  base=None
  if baseline:
   base_case=output/'baseline';base_case.mkdir()
   base=launch([str(binary),'--baseline','--duration','331','--output',str(base_case)],base_case/'process.log')
  started=time.monotonic();next_report=30;screenshot=False
  while glass.poll() is None:
   elapsed=time.monotonic()-started
   if elapsed>350:raise RuntimeError(f'{name} timeout')
   latest=case/'runtime-latest.json'
   if latest.exists():
    state=json.loads(latest.read_text())
    if state.get('desktop_blockers') or state.get('pause_reasons') or state['state'] in ['failed','permission_required','desktop_unavailable']:
     (case/'interruption.json').write_text(json.dumps({'status':'BLOCKED_VERIFICATION','elapsed_seconds':elapsed,'runtime':state},indent=2))
     raise RuntimeError('BLOCKED_VERIFICATION: desktop or capture became unavailable; no further scenes will run')
   if elapsed>=next_report:
    print(f'{name}: {int(elapsed)} / 331 seconds',flush=True);next_report+=30
   if elapsed>=40 and not screenshot:
    ready=json.loads((case/'ready.json').read_text())
    subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'window.png')],check=True)
    screenshot=True
   time.sleep(1)
  assert glass.returncode==0,(case/'process.log').read_text()
  if base is not None:assert base.wait(timeout=15)==0
  assert not (case/'runtime-error.json').exists(),(case/'runtime-error.json').read_text() if (case/'runtime-error.json').exists() else ''
  assert len(list(case.glob('geometry-*.json')))==1,'Measurement geometry changed during a fixed scene'
  print(f'{name} complete: {case}',flush=True)
 finally:
  for p in processes:
   if p.poll() is None:p.terminate();p.wait(timeout=10)
  for h in handles:h.close()

power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
try:
 if large_first:
  scene('large',large=True,animated=True)
  from analyze_performance import analyze
  large=analyze(output/'large',True)
  checks={'memory_stable':large['memory_slope_mib_per_minute']<=1 and large['memory_last_minus_first_minute_mib']<=5}
  (output/'large-gate.json').write_text(json.dumps({'status':'PASS' if all(checks.values()) else 'FINDINGS','results':large,'checks':checks},indent=2))
  if not all(checks.values()):raise RuntimeError('Maximum-size memory finding; remaining scenes not run')
 if not static_only:
  scene('dynamic',animated=True)
  # Stop on the previously failing scene before collecting unrelated evidence.
  from analyze_performance import analyze
  dynamic=analyze(output/'dynamic')
  checks={'cpu':dynamic['cpu_median_percent']<=15,
          'gpu':dynamic['gpu_p95_ms'] is not None and dynamic['gpu_p95_ms']<=12,
          'fps':27<=dynamic['fps_median']<=30,
          'frame_interval':dynamic['presentation_interval_p95_ms'] is not None and dynamic['presentation_interval_p95_ms']<=50,
          'latency':dynamic['latency_p95_ms'] is not None and dynamic['latency_p95_ms']<=100 and dynamic['latency_max_ms']<=250,
          'memory_stable':dynamic['memory_slope_mib_per_minute']<=1 and dynamic['memory_last_minus_first_minute_mib']<=5}
  (output/'dynamic-gate.json').write_text(json.dumps({'status':'PASS' if all(checks.values()) else 'FINDINGS','results':dynamic,'checks':checks},indent=2))
  if not all(checks.values()):raise RuntimeError('Dynamic budget finding; remaining scenes not run')
 scene('static',baseline=True)
 if not static_only:
  if not large_first:scene('large',large=True,animated=True)
  if not core_only:scene('effects_off',animated=True,flags=['--no-outer-glow','--no-inner-glow','--no-edge'])
  subprocess.run(['python3',str(root/'scripts/analyze_performance.py'),str(output),str(cycles)],check=True)
 else:
  from analyze_performance import analyze
  values={name:analyze(output/name) for name in ['baseline','static']}
  s,b=values['static'],values['baseline']
  state=json.loads((output/'static/runtime-latest.json').read_text())
  checks={'static_cpu':s['cpu_median_percent']<=3,'static_memory_delta':s['resident_median_mib']-b['resident_median_mib']<=128,
          'static_memory_stable':s['memory_slope_mib_per_minute']<=1 and s['memory_last_minus_first_minute_mib']<=5,
          'static_no_repeat_render':s['gpu_sample_count']==0 and state['gpu_submissions']==1 and state['blur_encodes']==1}
  (output/'result.json').write_text(json.dumps({'scope':'static_only','status':'PASS' if all(checks.values()) else 'FINDINGS','results':values,'checks':checks},indent=2))
finally:
 if power.poll() is None:power.terminate();power.wait(timeout=5)
print(output,flush=True)
