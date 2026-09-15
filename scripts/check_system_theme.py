#!/usr/bin/env python3
"""Real system appearance change through supported System Events preferences; restore it."""
import argparse,json,subprocess,tempfile,time
from pathlib import Path
from material_test_support import *
def theme():return subprocess.check_output(['osascript','-e','tell application "System Events" to get dark mode of appearance preferences'],text=True).strip()=='true'
def set_theme(dark):subprocess.run(['osascript','-e',f'tell application "System Events" to set dark mode of appearance preferences to {str(dark).lower()}'],check=True)
parser=argparse.ArgumentParser();parser.add_argument('--accessibility',action='store_true',help='Require real Reduce Motion and Reduce Transparency switches; never inject them');args=parser.parse_args()
original=theme();run=Path(tempfile.mkdtemp(prefix='glass-system-theme-',dir='/private/tmp'));print('RUN',run,flush=True)
app=make_test_app(run);case=run/'theme';case.mkdir();back=None;pid=None;rows=[]
try:
 back=subprocess.Popen([str(FIXTURE),'--large','--background','pattern' if args.accessibility else 'dark','--duration','16'],stdout=subprocess.DEVNULL)
 time.sleep(.4);permission=launch_system(app,case,None,duration=12,extra=['--border-flow']);pid=permission['pid']
 for n,dark in enumerate([original,not original,original]):
  set_theme(dark);time.sleep(1.3)
  state=wait_json(case/'runtime-latest.json')
  assert state['appearance_target']==(0 if dark else 1),state
  assert state['appearance_light_weight']==state['appearance_target'] and state['last_presented_light_weight']==state['appearance_target'],state
  if args.accessibility:
   assert state['reduce_motion_source']=='system' and state['reduce_motion'] and state['reduce_transparency'],state
   assert not state['flow_running'] and state['flow_visible'],state
   if rows:assert abs(state['flow_phase']-rows[0]['state']['flow_phase'])<1e-6,state
  else:assert state['flow_running'],state
  screenshot(case,f'theme-{n}');rows.append({'system_dark':dark,'state':state})
 wait_json(case/'termination.json',timeout=15)
 (run/'result.json').write_text(json.dumps({'scope':'real_system_accessibility_and_appearance' if args.accessibility else 'real_system_appearance_change','original_dark':original,'restored_dark':theme(),'observations':rows,'permission':permission},indent=2));print('FINISHED',run,flush=True)
finally:
 set_theme(original)
 stop_pid(pid)
 if back and back.poll() is None:back.terminate();back.wait(timeout=5)
