#!/usr/bin/env python3
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
root=Path(__file__).resolve().parents[1]
output=root/'docs/evidence'/('WP-03-geometry-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
output.mkdir(parents=True,exist_ok=False)
seen=[]
with (output/'process.log').open('w') as log:
    process=subprocess.Popen([str(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab'),'--capture-probe','--geometry-probe','--duration','7','--output',str(output)],stdout=log,stderr=subprocess.STDOUT)
    try:
        deadline=time.monotonic()+20
        while process.poll() is None:
            if time.monotonic()>deadline: raise RuntimeError('Capture geometry timeout')
            latest=output/'capture-latest.json'
            if latest.exists():
                state=json.loads(latest.read_text())
                signature=(state['source_rect_pt'],state['buffer_width_px'],state['buffer_height_px'])
                if not seen or signature!=seen[-1][0]: seen.append((signature,state))
            time.sleep(.05)
        assert process.returncode==0
        sizes=[(s['buffer_width_px'],s['buffer_height_px']) for _,s in seen]
        assert (472,122) in sizes and (872,222) in sizes, sizes
        assert any(w>872 and h>222 for w,h in sizes), sizes
        assert sizes[-1]==(472,122), sizes
        stop=json.loads((output/'capture-stop.json').read_text())
        assert stop['state']=='stopped' and stop['retained_buffers']==0
        assert all(s['retained_buffers']<=1 and not s['error'] for _,s in seen)
        (output/'result.json').write_text(json.dumps({'status':'PASS','states':[s for _,s in seen],'stop':stop},indent=2))
        print(f'PASS live sourceRect and buffer resize: {output}')
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=10)
