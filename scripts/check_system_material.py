#!/usr/bin/env python3
"""Real WindowServer base comparison / system appearance matrix, finite temporary app."""
import argparse,json,subprocess,tempfile,time
from pathlib import Path
from PIL import Image,ImageDraw,ImageStat,ImageChops
from material_test_support import *
parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['base','visual'],default='base',nargs='?');args=parser.parse_args()
run=Path(tempfile.mkdtemp(prefix='glass-system-'+args.mode+'-',dir='/private/tmp'))
print('RUN',run,flush=True)
app=make_test_app(run); results=[]; pictures=[]
if args.mode=='base': cases=[('custom-pattern','custom','pattern',None),('system-light-pattern','system','pattern','light'),('system-dark-pattern','system','pattern','dark')]
else: cases=[(f'{theme}-{bg}','system',bg,theme) for theme in ['light','dark'] for bg in ['white','gray','dark','warm','cool','pattern']]
for name,backend,background,appearance in cases:
    case=run/name;case.mkdir();back=source=None;pid=None
    try:
        back=subprocess.Popen([str(FIXTURE),'--large','--background',background,'--animate','--duration','12'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        time.sleep(.5)
        if backend=='system':
            permission=launch_system(app,case,appearance,duration=7,extra=['--border-flow','--test-static-flow'] if args.mode=='visual' else [])
            pid=permission['pid']
        else:
            source=subprocess.Popen([str(BINARY),'--duration','7','--no-permission-prompt','--output',str(case)],stdout=subprocess.DEVNULL)
            permission=None
            wait_json(case/'runtime-latest.json')
        time.sleep(1)
        first=screenshot(case); assert first.size==(824,124),first.size
        time.sleep(.7)
        later=screenshot(case,'later')
        state=wait_json(case/'runtime-latest.json')
        row={'name':name,'state':state,'permission_test':permission,
             'temporal_mean_difference':sum(ImageStat.Stat(ImageChops.difference(first,later)).mean)/3}
        if background=='pattern': assert row['temporal_mean_difference']>1,row
        if backend=='system': assert state['capture_service_initializations']==0,row
        wait_json(case/'termination.json',timeout=10)
        if source:source.wait(timeout=3)
        results.append(row);pictures.append((name,first));print('CAPTURED',name,flush=True)
    finally:
        if source and source.poll() is None:source.terminate();source.wait(timeout=5)
        stop_pid(pid)
        if back and back.poll() is None:back.terminate();back.wait(timeout=5)
sheet=Image.new('RGB',(824,len(pictures)*156),(35,35,35));draw=ImageDraw.Draw(sheet)
for i,(name,im) in enumerate(pictures):draw.text((12,i*156+7),name,fill='white');sheet.paste(im,(0,i*156+28))
sheet.save(run/'contact.png')
(run/'result.json').write_text(json.dumps({'scope':'actual_native_windows_visual_review_required','cases':results},indent=2))
print('FINISHED',run,flush=True)
