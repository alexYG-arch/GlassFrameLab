#!/usr/bin/env python3
"""One 85-second system functional run and one serial custom comparison. No long RSS gate."""
import argparse,csv,json,math,statistics,subprocess,tempfile,time
from pathlib import Path
from material_test_support import *
parser=argparse.ArgumentParser();parser.add_argument('--backend',choices=['custom','system','both'],default='both');args=parser.parse_args()
ws_pid=subprocess.run(['pgrep','-x','WindowServer'],capture_output=True,text=True).stdout.strip().splitlines()
run=Path(tempfile.mkdtemp(prefix='glass-system-smoke-',dir='/private/tmp'))
print('RUN',run,flush=True)
app=make_test_app(run);results={}
for backend in (['custom','system'] if args.backend=='both' else [args.backend]):
 case=run/backend;case.mkdir();back=source=awake=None;pid=None;ws=[]
 try:
  awake=subprocess.Popen(['/usr/bin/caffeinate','-d','-i','-t','100'])
  back=subprocess.Popen([str(FIXTURE),'--large','--background','dark','--upgrade-background','--duration','95'],stdout=subprocess.DEVNULL)
  time.sleep(.7)
  started=time.monotonic()
  if backend=='system':
   permission=launch_system(app,case,'dark',duration=85,extra=['--upgrade-probe'])
   pid=permission['pid'];assert permission['screen_capture_preflight'] is False,permission
  else:
   permission=None
   log=(case/'process.log').open('w')
   source=subprocess.Popen([str(BINARY),'--upgrade-probe','--duration','85','--no-permission-prompt','--output',str(case)],stdout=log,stderr=subprocess.STDOUT)
  # Window/probe startup can take longer through LaunchServices. Align images
  # to the first observation's process clock rather than open() wall time.
  probe_offset=wait_json(case/'upgrade-probe-start.json')['uptime']-started
  captures={4+probe_offset:'off',31+probe_offset:'on',35+probe_offset:'light-flow',42+probe_offset:'drag',47+probe_offset:'resize',68+probe_offset:'shown'}
  next_log=5;next_ws=5
  while not (case/'termination.json').exists():
   elapsed=time.monotonic()-started
   if elapsed>95:raise RuntimeError('Finite probe exceeded bound '+backend)
   if source and source.poll() is not None:raise RuntimeError('Source exited before termination receipt '+str(source.returncode))
   if elapsed>=next_log:
    state=wait_json(case/'runtime-latest.json')
    print('STAGE',backend,round(elapsed),{k:state.get(k) for k in ['material_visible','flow_running','flow_phase','gpu_submissions','decoration_error']},flush=True)
    if state.get('desktop_blockers') or state.get('screen_capture_permission') is False:raise RuntimeError('Desktop or custom capture unavailable')
    next_log+=25
   if elapsed>=next_ws and elapsed<=30:
    # Whole WindowServer process: contextual only, includes unrelated windows.
    sample=subprocess.run(['ps','-p',','.join(ws_pid),'-o','%cpu=,rss='],capture_output=True,text=True) if ws_pid else None
    ws.append({'elapsed':elapsed,'ps_cpu_percent_and_rss_kib':sample.stdout.strip() if sample and sample.returncode==0 else None});next_ws+=1
   for at,name in list(captures.items()):
    if elapsed>=at:screenshot(case,name);del captures[at];print('CAPTURED',backend,name,flush=True)
   time.sleep(.2)
  observations=wait_json(case/'upgrade-observations.json')['observations'];by={r['stage']:r for r in observations}
  checks={
   'off_static_no_submissions':by['off-start']['gpu_submissions']==by['off-end']['gpu_submissions'],
   'drag_frozen':abs(by['drag-start']['flow_phase']-by['drag-end']['flow_phase'])<1e-6,
   'resize_frozen':abs(by['resize-start']['flow_phase']-by['resize-end']['flow_phase'])<1e-6,
   'drag_visible':by['drag-start']['flow_visible'] and by['drag-end']['flow_visible'],
   'resize_visible':by['resize-start']['flow_visible'] and by['resize-end']['flow_visible'],
   'once_finished':by['once-start']['flow_running'] and not by['once-finished']['flow_running'] and not by['once-finished']['flow_visible'],
   'resumed':by['resumed']['flow_running'],
   'off_cleared':not by['toggled-off']['flow_visible'] and not by['toggled-off']['flow_running'],
   'hidden_paused':not by['hidden']['flow_running'] and not by['hidden']['window_visible'],
   'hidden_no_submissions':by['hidden-start']['gpu_submissions']==by['hidden-end']['gpu_submissions'],
   'shown':by['shown']['flow_running'] and by['shown']['material_visible'],
   'menu_close_exits':wait_json(case/'termination.json')['exit_status']==0}
  if backend=='system':
   checks.update({
    'no_capture_initialization':all(r['capture_service_initializations']==0 for r in observations),
    'normal_app_without_recording_grant':permission['screen_capture_preflight'] is False,
    'theme_callback_light_dark':by['light']['appearance_light_weight']==1 and by['dark']['appearance_light_weight']==0,
    'reduce_motion_frozen':abs(by['reduce-motion-start']['flow_phase']-by['reduce-motion-end']['flow_phase'])<1e-6,
    'reduce_motion_visible':by['reduce-motion-start']['flow_visible'] and by['reduce-motion-end']['flow_visible'],
    'reduced_motion_theme_actually_presented':by['reduce-motion-end']['last_presented_light_weight']==1,
    'nested_pause_retained':by['nested-pause']['pause_reasons']==['session'] and not by['nested-pause']['flow_running'],
    'independent_reduce_motion_pause':by['session-restored-motion-reduced']['pause_reasons']==[] and not by['session-restored-motion-reduced']['flow_running'],
    'once_not_restarted_by_theme':by['once-theme-change']['flow_finished'] and not by['once-theme-change']['flow_running'],
    'stop_cancels_animation':not wait_json(case/'system-stop.json')['overlay_animation_pending']})
  samples=list(csv.DictReader((case/'samples.csv').open()));frames=list(csv.DictReader((case/'frames.csv').open()))
  start_uptime=wait_json(case/'ready.json')['measurement_start_uptime']
  def segment(a,b):
   rows=[r for r in samples if a<=float(r['elapsed_seconds'])<=b]
   gpu=[float(r['gpu_ms']) for r in frames if a<=float(r['presented_seconds'])-start_uptime<=b]
   return {'duration_seconds':b-a,'cpu_median_one_core_percent':statistics.median(float(r['cpu_percent_one_core']) for r in rows),
    'rss_first_mib':int(rows[0]['resident_bytes'])/1048576,'rss_last_mib':int(rows[-1]['resident_bytes'])/1048576,
    'rss_peak_mib':max(int(r['resident_bytes']) for r in rows)/1048576,'overlay_or_custom_command_gpu_p95_ms':sorted(gpu)[math.ceil(len(gpu)*.95)-1] if gpu else None,'presented_fps':len(gpu)/(b-a)}
  result={'scope':'LaunchServices_system_and_source_custom_functional_checks','checks':checks,'off':segment(5,12),'on':segment(16,30),'windowserver_process_observations':ws,'total_gpu_power':'unmeasured','observations':observations}
  (case/'summary.json').write_text(json.dumps(result,indent=2));results[backend]=result
  print('RESULT',backend,json.dumps({k:v for k,v in result.items() if k in ['checks','off','on']}),flush=True)
  if not all(checks.values()):raise RuntimeError('Functional failures '+str([k for k,v in checks.items() if not v]))
 finally:
  stop_pid(pid)
  for p in [source,back,awake]:
   if p and p.poll() is None:p.terminate();p.wait(timeout=5)
(run/'summary.json').write_text(json.dumps(results,indent=2));print('FINISHED',run,flush=True)
