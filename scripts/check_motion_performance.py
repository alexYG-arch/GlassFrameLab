#!/usr/bin/env python3
"""Continuous native dragging through the product geometry path; --quick is diagnostic only."""
import csv,json,math,os,re,statistics,subprocess,sys,time
from datetime import datetime,timezone
from pathlib import Path
from analyze_performance import analyze,p95,presentation_intervals
root=Path(__file__).resolve().parents[1]
assert all(arg in ['--quick','--resize'] for arg in sys.argv[1:])
quick='--quick' in sys.argv[1:]
resize='--resize' in sys.argv[1:]
kind='resize' if resize else 'drag'
duration=43 if quick else 333
out=root/'docs/evidence'/('WP-07-'+kind+'-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
processes=[];handles=[]
def launch(args,name):
 handle=(out/name).open('w');handles.append(handle)
 p=subprocess.Popen(args,stdout=handle,stderr=subprocess.STDOUT);processes.append(p);return p
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
try:
 launch([str(fixture),'--large','--animate','--duration',str(duration+15)],'fixture.log')
 time.sleep(1)
 app=launch([str(binary),'--test-corner','--resize-performance' if resize else '--motion-performance','--duration',str(duration),'--output',str(out)],'process.log')
 start=time.monotonic();next_report=30;shot=False
 while app.poll() is None:
  elapsed=time.monotonic()-start
  if elapsed>duration+15:raise RuntimeError('Motion measurement timeout')
  latest=out/'runtime-latest.json'
  if latest.exists():
   state=json.loads(latest.read_text())
   if state.get('desktop_blockers') or state.get('pause_reasons') or state['state'] in ['failed','permission_required','desktop_unavailable']:
    (out/'result.json').write_text(json.dumps({'status':'BLOCKED_VERIFICATION','binary':str(binary),'fixture':str(fixture),
      'elapsed_seconds':elapsed,'runtime':state,'reason':'Desktop or capture unavailable; not a completed performance measurement'},indent=2))
    raise RuntimeError('BLOCKED_VERIFICATION: desktop or capture unavailable')
  if elapsed>=next_report:print(f'{kind}: {int(elapsed)} / {duration} seconds',flush=True);next_report+=30
  if elapsed>=20 and not shot:
   ready=json.loads((out/'ready.json').read_text())
   subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(out/'window.png')],check=True);shot=True
  time.sleep(.5)
 assert app.returncode==0
 assert not (out/'runtime-error.json').exists()
finally:
 for p in processes:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
 for h in handles:h.close()
 if power.poll() is None:power.terminate();power.wait(timeout=5)
ready=json.loads((out/'ready.json').read_text());start=ready['measurement_start_uptime']
if quick:
 rows=list(csv.DictReader((out/'frames.csv').open()))
 frames=[r for r in rows if start+10<=float(r['captured_seconds'])<start+40]
 shown=[r for r in frames if float(r['presented_seconds'])>0]
 counts=[sum(start+10+i<=float(r['presented_seconds'])<start+11+i for r in shown) for i in range(30)]
 result={'fps_median':statistics.median(counts),'presentation_interval_p95_ms':p95(presentation_intervals([r['presented_seconds'] for r in shown])),
         'gpu_p95_ms':p95([float(r['gpu_ms']) for r in frames]),'latency_p95_ms':p95([float(r['latency_ms']) for r in shown]),
         'latency_max_ms':max((float(r['latency_ms']) for r in shown),default=None)}
else:result=analyze(out)
state=json.loads((out/'runtime-latest.json').read_text())
geometry=[json.loads(p.read_text()) for p in out.glob('geometry-*.json')]
assert len(geometry)>duration*10,'Dragging did not exercise the geometry path'
if not resize:assert all(g['actual_size_px']=='{800, 100}' for g in geometry)
if resize:
 def center(frame):
  x,y,w,h=map(float,re.findall(r'-?[0-9.]+',frame));return (x+w/2,y+h/2)
 initial=center(ready['frame_pt'])
 assert all(max(abs(a-b) for a,b in zip(center(g['frame_pt']),initial))<=1 for g in geometry),'Resize anchor drifted'

assert geometry and state['glass_frame_pt']==state['rendered_glass_frame_pt']
assert state['capture_envelope_pt']=='none' and not state['geometry_motion_active']
checks={'fps':27<=result['fps_median']<=30,'interval':result['presentation_interval_p95_ms'] is not None and result['presentation_interval_p95_ms']<=50,
        'gpu':result['gpu_p95_ms'] is not None and result['gpu_p95_ms']<=12,
        'latency':result['latency_p95_ms'] is not None and result['latency_p95_ms']<=100 and result['latency_max_ms']<=250}
if not quick:checks.update(cpu=result['cpu_median_percent']<=15,memory_stable=result['memory_slope_mib_per_minute']<=1 and result['memory_last_minus_first_minute_mib']<=5)
(out/'result.json').write_text(json.dumps({'status':('DIAGNOSTIC_PASS' if quick else 'PASS') if all(checks.values()) else 'FINDINGS',
 'quick':quick,'kind':kind,'size_range':sorted(set(g['actual_size_px'] for g in geometry)),'binary':str(binary),'fixture':str(fixture),'checks':checks,'metrics':result,'geometry_commits':len(geometry),'final':state},indent=2))
print(out,flush=True)
raise SystemExit(0 if all(checks.values()) else 1)
