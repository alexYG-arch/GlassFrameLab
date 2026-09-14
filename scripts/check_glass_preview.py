#!/usr/bin/env python3
import io
import json
import struct
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from PIL import Image,ImageCms,ImageStat,ImageFilter
root=Path(__file__).resolve().parents[1]
output=root/'docs/evidence'/('WP-04-preview-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
output.mkdir(parents=True,exist_ok=False)
results=[]
for name,args in [('sigma0',['--sigma','0']),('sigma12',['--sigma','12']),('foreground',['--sigma','12','--foreground-probe'])]:
    case=output/name
    case.mkdir()
    with (case/'process.log').open('w') as log:
        process=subprocess.Popen([str(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab'),'--glass-preview','--duration','5','--output',str(case),*args],stdout=log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+20
            captured=False
            while process.poll() is None:
                if time.monotonic()>deadline: raise RuntimeError('Glass preview timeout')
                if (case/'glass-render.json').exists() and not captured:
                    time.sleep(.2)
                    ready=json.loads((case/'ready.json').read_text())
                    subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(case/'window.png')],check=True)
                    captured=True
                time.sleep(.05)
            assert process.returncode==0, (case/'process.log').read_text()
            render=json.loads((case/'glass-render.json').read_text())
            stop=json.loads((case/'capture-stop.json').read_text())
            assert render['submissions']==1 and render['rendered'] and render['gpu_command_ms']>0
            assert stop['state']=='stopped' and stop['retained_buffers']==0
            data=(case/'window.png').read_bytes()
            assert struct.unpack('>II',data[16:24])==(824,124)
            im=Image.open(case/'window.png')
            assert im.mode=='RGBA' and all(im.getpixel(p)[3]==0 for p in [(0,0),(823,0),(0,123),(823,123)]) and im.getpixel((412,62))[3]>250
            results.append({'case':name,'render':render,'capture_stop':stop})
        finally:
            if process.poll() is None: process.terminate();process.wait(timeout=10)
(output/'result.json').write_text(json.dumps({'status':'STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED','cases':results},indent=2))
print(f'Single-frame GPU and alpha checks passed; inspect screenshots: {output}')
