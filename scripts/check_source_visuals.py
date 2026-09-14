#!/usr/bin/env python3
"""Source executable visual matrix. No app packaging; OS launch is a separate gate."""
import json, re, subprocess, tempfile, time, sys
from io import BytesIO
from pathlib import Path
from PIL import Image, ImageDraw, ImageStat, ImageChops, ImageCms
root=Path(__file__).resolve().parents[1]
run=Path(tempfile.mkdtemp(prefix='glass-source-visual-',dir='/private/tmp'))
binary=(root/'.build/release/GlassFrameLab').resolve()
fixture=root/'.build/GlassFrameFixture'
results=[]
def screenshot_rgb(path):
    image=Image.open(path)
    # macOS screenshots carry the display profile. convert('RGB') alone does
    # not transform it; pasting those bytes into an untagged sheet dulls blues.
    profile=image.info.get('icc_profile')
    if profile:
        return ImageCms.profileToProfile(image.convert('RGB'),ImageCms.ImageCmsProfile(BytesIO(profile)),ImageCms.createProfile('sRGB'),outputMode='RGB')
    return image.convert('RGB')
print('RUN',run,flush=True)
default_cases=['white','gray','black','deepgray','dark-detail','mixed','narrow','checker','pattern','flow-loop','dark-no-adaptive','permission-denied','metal-unavailable']
for name in (sys.argv[1].split(',') if len(sys.argv)>1 else default_cases):
    case=run/name;case.mkdir();procs=[];finder_id=None
    backdrop='dark' if name in ['dark-no-adaptive','flow-loop'] else ('pattern' if name in ['permission-denied','metal-unavailable'] else name)
    if name in ['white-flow','gray-flow']:backdrop=name.split('-')[0]
    with (case/'fixture.log').open('w') as log,(case/'process.log').open('w') as app_log:
        try:
            if name=='finder':
                script='on run argv\n tell application "Finder"\n set w to make new Finder window to POSIX file (item 1 of argv)\n set bounds of w to {60,100,950,720}\n activate\n return id of w\n end tell\nend run'
                finder_id=int(subprocess.check_output(['osascript','-e',script,str(root)],text=True).strip())
            else:
                procs.append(subprocess.Popen([str(fixture),'--large','--background',backdrop,'--duration','25']+(['--animate'] if name=='pattern' else []),stdout=log,stderr=subprocess.STDOUT))
            time.sleep(.5)
            args=[str(binary),'--no-permission-prompt','--duration','22','--output',str(case)]
            if name=='dark-no-adaptive':args+=['--no-adaptive-material']
            if name in ['flow-loop','white-flow','gray-flow']:args+=['--border-flow']
            if name=='finder':args+=['--test-corner','--border-flow']
            if name=='permission-denied':args+=['--test-permission-denied']
            if name=='metal-unavailable':args+=['--test-metal-unavailable']
            procs.append(subprocess.Popen(args,stdout=app_log,stderr=subprocess.STDOUT))
            deadline=time.monotonic()+15
            while True:
                runtime=case/'runtime-latest.json'; failure=case/'runtime-error.json'
                state=json.loads(runtime.read_text()) if runtime.exists() else (json.loads(failure.read_text()) if failure.exists() else {})
                if state.get('material_visible') or (name in ['permission-denied','metal-unavailable'] and state.get('fallback_visible')):break
                if state.get('desktop_blockers'):raise RuntimeError('Desktop unavailable: '+str(state['desktop_blockers']))
                if procs[-1].poll() is not None or time.monotonic()>deadline:raise RuntimeError('No render state: '+str(state))
                time.sleep(.15)
            ready=json.loads((case/'ready.json').read_text())
            failed=name in ['permission-denied','metal-unavailable']
            if failed: assert state['fallback_visible'] and not state.get('material_visible',False),state
            else: assert state['material_visible'] and state['fallback_reason']=='none',state
            win=case/'window.png'
            subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(win)],check=True)
            x,y,w,h=map(float,re.findall(r'-?[\d.]+',ready['frame_pt']))
            env=json.loads((case/'environment.json').read_text());sx,sy,sw,sh=map(float,re.findall(r'-?[\d.]+',env['screens'][0]['frame_pt']))
            subprocess.run(['/usr/sbin/screencapture','-x','-R',f'{int(x-20)},{int(sy+sh-y-h-20)},{int(w+40)},{int(h+40)}',str(case/'context.png')],check=True)
            im=screenshot_rgb(win);assert im.size==(824,124)
            sample=im.crop((40,40,784,84));row={'case':name,'state':state,'center_rgb':ImageStat.Stat(sample).mean,'center_stddev':ImageStat.Stat(sample).stddev}
            if name=='pattern':
                time.sleep(1)
                subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'later.png')],check=True)
                later=screenshot_rgb(case/'later.png')
                row['temporal_mean_difference']=sum(ImageStat.Stat(ImageChops.difference(im,later)).mean)/3
                assert row['temporal_mean_difference']>1,row
            if name in ['flow-loop','white-flow','gray-flow']:
                for phase in range(8):
                    subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/('phase-'+str(phase)+'.png'))],check=True)
                    time.sleep(.85)
            results.append(row);print('CAPTURED',name,flush=True)
        finally:
            for p in procs:
                if p.poll() is None:p.terminate();p.wait(timeout=5)
            if finder_id is not None:subprocess.run(['osascript','-e',f'tell application "Finder" to close Finder window id {finder_id}'],check=True)
images=[screenshot_rgb(run/r['case']/'context.png') for r in results]
sheet=Image.new('RGB',(max(i.width for i in images),sum(i.height+28 for i in images)),(40,40,40));draw=ImageDraw.Draw(sheet);y=0
for row,im in zip(results,images):
    draw.text((10,y+5),row['case'],fill='white');sheet.paste(im,(0,y+28));y+=im.height+28
sheet.save(run/'contact.png')
(run/'result.json').write_text(json.dumps({'scope':'source_process_only_visual_review_required','binary':str(binary),'cases':results},indent=2))
print('FINISHED',run,flush=True)
