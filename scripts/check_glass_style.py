#!/usr/bin/env python3
"""Actual native screenshots; generated backgrounds are explicit test fixtures."""
import json, re, subprocess, time
from datetime import datetime, timezone
from pathlib import Path
from PIL import Image

root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-06-visual-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
cases=[(f'{bg}-{size}',bg,[] if size=='default' else ['--width-px','1600','--height-px','600'])
       for bg in ['white','gray','warm','cool','dark','pattern'] for size in ['default','large']]
cases += [(f'{bg}-{layer}',bg,[flag]) for bg in ['white','dark','pattern']
          for layer,flag in [('no-outer','--no-outer-glow'),('no-inner','--no-inner-glow'),('no-edge','--no-edge')]]
cases += [('foreground','pattern',['--foreground-probe'])]
results=[]
for name,bg,args in cases:
    case=out/name;case.mkdir()
    with (case/'fixture.log').open('w') as f,(case/'process.log').open('w') as log:
        back=subprocess.Popen([str(fixture),'--large','--background',bg,'--duration','12'],stdout=f,stderr=subprocess.STDOUT)
        process=None
        try:
            time.sleep(.5)
            process=subprocess.Popen([str(binary),'--glass-preview','--test-corner','--duration','4','--output',str(case),*args],stdout=log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+10
            while not (case/'glass-render.json').exists():
                if process.poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError(f'No glass frame: {case} {(case/"process.log").read_text()}')
                time.sleep(.05)
            time.sleep(.2)
            ready=json.loads((case/'ready.json').read_text())
            subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'window.png')],check=True)
            x,y,w,h=map(float,re.findall(r'-?[\d.]+',ready['frame_pt']))
            environment=json.loads((case/'environment.json').read_text())
            sx,sy,sw,sh=map(float,re.findall(r'-?[\d.]+',environment['screens'][0]['frame_pt']))
            region=f'{int(x-16)},{int(sy+sh-y-h-16)},{int(w+32)},{int(h+32)}'
            subprocess.run(['/usr/sbin/screencapture','-x','-R',region,str(case/'context.png')],check=True)
            process.wait(timeout=10)
            assert process.returncode==0
            render=json.loads((case/'glass-render.json').read_text())
            im=Image.open(case/'window.png')
            expected=(1624,624) if name.endswith('-large') else (824,124)
            assert im.size==expected,(name,im.size)
            assert im.mode=='RGBA' and all(im.getpixel(p)[3]==0 for p in [(0,0),(im.width-1,0),(0,im.height-1),(im.width-1,im.height-1)])
            assert render['submissions']==1 and render['local_intermediate_textures']==1 and render['blur_encodes']==1
            results.append({'case':name,'size':im.size,'gpu_ms':render['gpu_command_ms']})
            print('CAPTURED',name,flush=True)
        finally:
            if process is not None and process.poll() is None:process.terminate();process.wait(timeout=10)
            if back.poll() is None:back.terminate();back.wait(timeout=10)
(out/'result.json').write_text(json.dumps({'status':'STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED','binary':str(binary),'fixture':str(fixture),'cases':results},indent=2))
print(out,flush=True)
