#!/usr/bin/env python3
"""Full native flow loop, actual Finder movement and Metal-unavailable base."""
import json,subprocess,tempfile,time
from pathlib import Path
from PIL import Image,ImageDraw,ImageChops,ImageStat
from material_test_support import *
run=Path(tempfile.mkdtemp(prefix='glass-system-edges-',dir='/private/tmp'));print('RUN',run,flush=True)
app=make_test_app(run);results=[];pictures=[]
for name in ['light-loop','dark-loop','finder','metal-unavailable']:
 case=run/name;case.mkdir();back=None;pid=None;finder=None
 try:
  if name=='finder':
   script='on run argv\n tell application "Finder"\n set w to make new Finder window to POSIX file (item 1 of argv)\n set bounds of w to {60,100,950,720}\n set current view of w to icon view\n activate\n return id of w\n end tell\nend run'
   finder=int(subprocess.check_output(['osascript','-e',script,str(ROOT)],text=True).strip())
  else:
   back=subprocess.Popen([str(FIXTURE),'--large','--background','white' if name.startswith('light') else 'dark','--duration','15'],stdout=subprocess.DEVNULL)
  time.sleep(.5)
  extra=['--border-flow']
  if name=='finder':extra+=['--test-corner','--test-static-flow']
  if name=='metal-unavailable':extra+=['--test-metal-unavailable']
  permission=launch_system(app,case,'light' if name in ['light-loop','finder'] else 'dark',duration=12,extra=extra)
  pid=permission['pid'];assert permission['screen_capture_preflight'] is False
  states=[];images=[]
  if name.endswith('loop'):
   for n in range(9):
    time.sleep(.9)
    images.append(screenshot(case,f'phase-{n}'))
    states.append(wait_json(case/'runtime-latest.json'))
   assert all(s['flow_running'] and s['flow_visible'] for s in states),states
   changes=[sum(ImageStat.Stat(ImageChops.difference(a,b)).mean) for a,b in zip(images,images[1:])]
   assert min(changes)>.05,changes
   row={'case':name,'frames':len(images),'phase_samples':[s['flow_phase'] for s in states],'sum_rgb_mean_changes':changes}
   for n in [0,2,4,6,8]:pictures.append((name+f' frame {n}',images[n]))
  elif name=='finder':
   time.sleep(1);first=screenshot(case)
   subprocess.run(['osascript','-e',f'tell application "Finder" to set bounds of Finder window id {finder} to {{100,140,990,760}}'],check=True)
   time.sleep(1);last=screenshot(case,'moved-finder')
   change=sum(ImageStat.Stat(ImageChops.difference(first,last)).mean)/3
   assert change>.2,change
   row={'case':name,'actual_finder_move_mean_rgb_difference':change};pictures.extend([('Finder before',first),('Finder moved',last)])
  else:
   time.sleep(1);state=wait_json(case/'runtime-latest.json')
   assert state['material_visible'] and not state['decoration_available'] and state['gpu_submissions']==0 and state['capture_service_initializations']==0,state
   row={'case':name,'state':state};pictures.append((name,screenshot(case)))
  row['permission_test']=permission
  wait_json(case/'termination.json',timeout=15)
  results.append(row);print('CHECKED',name,flush=True)
 finally:
  stop_pid(pid)
  if back and back.poll() is None:back.terminate();back.wait(timeout=5)
  if finder is not None:subprocess.run(['osascript','-e',f'tell application "Finder" to close Finder window id {finder}'],check=True)
sheet=Image.new('RGB',(824,len(pictures)*152),(40,40,40));draw=ImageDraw.Draw(sheet)
for i,(label,im) in enumerate(pictures):draw.text((8,i*152+5),label,fill='white');sheet.paste(im,(0,i*152+26))
sheet.save(run/'contact.png');(run/'result.json').write_text(json.dumps({'scope':'actual_native_composited_visual_review_required','cases':results},indent=2));print('FINISHED',run,flush=True)
