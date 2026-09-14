#!/usr/bin/env python3
"""One bounded 85-second native smoke run; temporary evidence, own-process cleanup."""
import csv,json,math,re,shutil,statistics,subprocess,tempfile,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
run=Path(tempfile.mkdtemp(prefix='glass-v13-smoke-',dir='/private/tmp'))
print('RUN',run,flush=True)
binary=(root/'.build/release/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture').resolve()
back=app=awake=None
try:
 awake=subprocess.Popen(['/usr/bin/caffeinate','-d','-i','-t','100'])
 with (run/'fixture.log').open('w') as f,(run/'process.log').open('w') as a:
  back=subprocess.Popen([str(fixture),'--large','--background','dark','--upgrade-background','--duration','95'],stdout=f,stderr=subprocess.STDOUT)
  time.sleep(1)
  start=time.monotonic()
  app=subprocess.Popen([str(binary),'--no-permission-prompt','--upgrade-probe','--duration','85','--output',str(run)],stdout=a,stderr=subprocess.STDOUT)
  captures={10:'dark-off',22:'dark-flow',35:'light-flow',42:'drag',47:'resize'}
  next_log=5
  while app.poll() is None:
   elapsed=time.monotonic()-start
   if elapsed>95: raise RuntimeError('Smoke run exceeded bound')
   if (run/'runtime-error.json').exists(): raise RuntimeError((run/'runtime-error.json').read_text())
   if elapsed>=next_log:
    if (run/'runtime-latest.json').exists():
     snap=json.loads((run/'runtime-latest.json').read_text())
     print('STAGE',round(elapsed),{k:snap.get(k) for k in ['material_visible','flow_running','flow_phase','gpu_submissions','blur_encodes','material_statistics_encodes','fallback_reason']},flush=True)
     if elapsed<15 and (snap.get('desktop_blockers') or snap.get('screen_capture_permission') is False):raise RuntimeError('Desktop unavailable: '+str(snap.get('desktop_blockers')))
    next_log+=30
   for at,name in list(captures.items()):
    if elapsed>=at:
     ready=json.loads((run/'ready.json').read_text())
     subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(run/(name+'.png'))],check=True)
     del captures[at]
     print('CAPTURED',name,flush=True)
   time.sleep(.5)
  if app.returncode:raise RuntimeError((run/'process.log').read_text())
 if not (run/'upgrade-observations.json').exists():raise RuntimeError('No smoke observations')
 rows=list(csv.DictReader((run/'samples.csv').open()))
 frames=list(csv.DictReader((run/'frames.csv').open()))
 observations=json.loads((run/'upgrade-observations.json').read_text())['observations']
 by={r['stage']:r for r in observations}
 def p95(xs):return sorted(xs)[math.ceil(len(xs)*.95)-1] if xs else None
 def segment(a,b):
  samples=[r for r in rows if a<=float(r['elapsed_seconds'])<=b]
  gpu=[float(r['gpu_ms']) for r in frames if a<=float(r['presented_seconds'])-json.loads((run/'ready.json').read_text())['measurement_start_uptime']<=b]
  return {'cpu_median':statistics.median(float(r['cpu_percent_one_core']) for r in samples),'rss_first_mib':int(samples[0]['resident_bytes'])/1048576,'rss_last_mib':int(samples[-1]['resident_bytes'])/1048576,'rss_peak_mib':max(int(r['resident_bytes']) for r in samples)/1048576,'gpu_p95_ms':p95(gpu),'fps':len(gpu)/(b-a)}
 checks={'off_static_no_submissions':by['off-start']['gpu_submissions']==by['off-end']['gpu_submissions'],
 'on_blur_bounded_by_background_changes':by['on-end']['blur_encodes']-by['on-start']['blur_encodes'] <= by['on-end']['changed_frames']-by['on-start']['changed_frames'],
 'on_statistics_bounded_by_background_changes':by['on-end']['material_statistics_encodes']-by['on-start']['material_statistics_encodes'] <= by['on-end']['changed_frames']-by['on-start']['changed_frames'],
 'drag_frozen':abs(by['drag-start']['flow_phase']-by['drag-end']['flow_phase'])<1e-6,
 'resize_frozen':abs(by['resize-start']['flow_phase']-by['resize-end']['flow_phase'])<1e-6,
 'drag_visible':by['drag-start']['flow_visible'] and by['drag-end']['flow_visible'],
 'resize_visible':by['resize-start']['flow_visible'] and by['resize-end']['flow_visible'],
 'once_finished':by['once-start']['flow_running'] and not by['once-finished']['flow_running'] and not by['once-finished']['flow_visible'],
 'resumed':by['resumed']['flow_running'],
 'off_cleared':not by['toggled-off']['flow_visible'] and not by['toggled-off']['flow_running'],
 'hidden_paused':not by['hidden']['flow_running'] and not by['hidden']['window_visible'],
 'shown':by['shown']['flow_running'] and by['shown']['material_visible']}
 result={'scope':'source_functional_probe_not_launchservices_acceptance','binary':str(binary),'off':segment(5,12),'on':segment(16,30),'checks':checks,'observations':observations}
 (run/'summary.json').write_text(json.dumps(result,indent=2))
 print(json.dumps({k:v for k,v in result.items() if k!='observations'},indent=2),flush=True)
 print('FINISHED',run,flush=True)
 if not all(checks.values()): raise RuntimeError('Functional checks failed')
finally:
 for p in [app,back,awake]:
  if p and p.poll() is None:
   p.terminate()
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait()
