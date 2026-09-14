#!/usr/bin/env python3
"""Native test fixture checks show/hide/move and an actual full-screen Space."""
import json
import math
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / "docs/evidence" / f"WP-01-lifecycle-{stamp}"
output.mkdir(parents=True, exist_ok=False)
binary = root / "build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab"
for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
    fields = line.strip().split(None,1)
    if len(fields)==2 and (fields[1]==str(binary) or fields[1].startswith(str(binary)+' ') or fields[1].startswith('build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab')):
        raise RuntimeError('Close other GlassFrameLab instances before this composite screenshot test')
captured = set()
with (output / "process.log").open('w') as log:
    process = subprocess.Popen([str(binary), '--window-probe', '--duration', '18', '--output', str(output)], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 30
        while process.poll() is None:
            if time.monotonic() > deadline:
                raise RuntimeError('Lifecycle test timeout')
            for stage in ('normal', 'fullscreen', 'restored'):
                path = output / f'window-probe-{stage}.json'
                if path.exists() and stage not in captured:
                    state = json.loads(path.read_text())
                    x,y,w,h = map(float, re.findall(r'-?[\d.]+',state['frame_rect_pt']))
                    env = json.loads((output / 'environment.json').read_text())
                    screen = env['screens'][0]
                    sx,sy,sw,sh = map(float,re.findall(r'-?[\d.]+',screen['frame_pt']))
                    rect = f'{math.floor(x-16)},{math.floor(sy+sh-y-h-16)},{math.ceil(w+32)},{math.ceil(h+32)}'
                    subprocess.run(['/usr/sbin/screencapture','-x','-R',rect,str(output/f'{stage}.png')],check=True)
                    captured.add(stage)
            time.sleep(0.1)
        assert process.returncode == 0
        states = {s:json.loads((output/f'window-probe-{s}.json').read_text()) for s in ('normal','hidden','reshown','fullscreen','restored')}
        assert not states['hidden']['frame_visible']
        assert all(states[s]['frame_visible'] and states[s]['frame_on_active_space'] for s in ('normal','reshown','fullscreen','restored'))
        assert states['fullscreen']['fixture_fullscreen']
        assert not states['restored']['fixture_fullscreen']
        result = {'status':'PASS','scope':'Show/hide/move and same-app native full-screen Space; not all third-party full-screen apps', 'states':states}
        (output/'result.json').write_text(json.dumps(result,indent=2))
        print(f'PASS window lifecycle: {output}')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
