#!/usr/bin/env python3
"""Finite current-product rim checks. Screenshots still require visual review.
Optional --baseline-app compares a supplied old build; no release ZIP is created.
"""
import argparse, sys, time, json, subprocess, tempfile
from pathlib import Path
from PIL import Image,ImageDraw
sys.path.insert(0,str(Path(__file__).resolve().parent))
from material_test_support import *
parser=argparse.ArgumentParser();parser.add_argument('--baseline-app',type=Path);args=parser.parse_args()
if args.baseline_app and not args.baseline_app.is_dir():parser.error('Baseline app does not exist')
run=Path(tempfile.mkdtemp(prefix='glass-rim-product-',dir='/private/tmp'));print('RUN',run,flush=True)
app=make_test_app(run)
baseline=args.baseline_app
subprocess.run(['swiftc','-O','-module-cache-path',str(ROOT/'.build/clang-cache'),str(ROOT/'Sources/GlassFrameLab/StaticGlassRim.swift'),str(ROOT/'Tests/Fixtures/StaticGlassRimCheck.swift'),'-o',str(run/'cache-check')],check=True)
cache=subprocess.run([str(run/'cache-check')],capture_output=True,text=True,check=True)
(run/'cache-check.json').write_text(cache.stdout)
json.loads(cache.stdout)
pictures=[];rows=[]
for theme in ['dark','light']:
 back=subprocess.Popen([str(FIXTURE),'--large','--background','dark' if theme=='dark' else 'white','--duration','30'],stdout=subprocess.DEVNULL)
 try:
  time.sleep(.5)
  for name,extra in [('baseline',[]),('off',[]),('on',['--border-flow','--test-static-flow','--flow-phase','0.485']),('metal-unavailable',['--border-flow','--test-metal-unavailable']),('large',['--width-px','1300','--height-px','220'])]:
   if name=='baseline' and baseline is None:continue
   case=run/(theme+'-'+name);case.mkdir();pid=None
   try:
    permission=launch_system(baseline if name=='baseline' else app,case,theme,duration=8,extra=extra)
    pid=permission['pid'];time.sleep(.7)
    if name=='on':
     deadline=time.monotonic()+4
     while not wait_json(case/'runtime-latest.json')['flow_visible'] and time.monotonic()<deadline:time.sleep(.15)
    im=screenshot(case);pictures.append((theme+' '+name,im))
    state=wait_json(case/'runtime-latest.json')
    assert state['material_visible'] and state['capture_service_initializations']==0,state
    if name=='metal-unavailable':assert state['gpu_submissions']==0 and not state['decoration_available'],state
    if name=='on':assert state['flow_visible'],state
    rows.append({'case':case.name,'state':state,'permission':permission})
    print('CAPTURED',case.name,flush=True)
   finally:stop_pid(pid);time.sleep(.15)
 finally:
  back.terminate();back.wait()
width=max(im.width for _,im in pictures);height=sum(im.height+25 for _,im in pictures)
sheet=Image.new('RGB',(width,height),(40,40,40));draw=ImageDraw.Draw(sheet);y=0
for label,im in pictures:
 draw.text((6,y+5),label,fill='white');sheet.paste(im,(0,y+25));y+=im.height+25
sheet.save(run/'review.png')
(run/'summary.json').write_text(json.dumps(rows,indent=2))
print('FINISHED',run,flush=True)
