#!/usr/bin/env python3
import json
import re
import struct
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
output = root / 'docs/evidence' / ('WP-02-geometry-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
output.mkdir(parents=True, exist_ok=False)
binary = root / 'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab'
captured = set()
with (output/'process.log').open('w') as log:
    process = subprocess.Popen([str(binary),'--geometry-probe','--duration','7','--output',str(output)],stdout=log,stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic()+20
        while process.poll() is None:
            if time.monotonic()>deadline:
                raise RuntimeError('Geometry probe timeout')
            if (output/'ready.json').exists():
                ready=json.loads((output/'ready.json').read_text())
                for number in (1,2,4):
                    if (output/f'geometry-{number:03d}.json').exists() and number not in captured:
                        # AppKit has committed; allow the compositor to publish that frame.
                        time.sleep(0.2)
                        target=output/f'geometry-{number:03d}.png'
                        subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(target)],check=True)
                        captured.add(number)
            time.sleep(0.1)
        assert process.returncode==0
        records=[json.loads(p.read_text()) for p in sorted(output.glob('geometry-*.json'))]
        assert len(records)==4, f'Expected four commits with duplicate suppressed, got {len(records)}'
        sizes=[list(map(float,re.findall(r'[\d.]+',r['actual_size_px']))) for r in records]
        assert sizes[0]==[800,100] and sizes[1]==[1600,300] and sizes[3]==[800,100]
        assert records[2]['size_limited'] and not records[3]['size_limited']
        rects=[list(map(float,re.findall(r'-?[\d.]+',r['frame_pt']))) for r in records]
        assert rects[0]==rects[3], 'Final minimum should restore the original center and frame'
        for number,expected in [(1,(824,124)),(2,(1624,324)),(4,(824,124))]:
            data=(output/f'geometry-{number:03d}.png').read_bytes()
            assert struct.unpack('>II',data[16:24])==expected
        (output/'result.json').write_text(json.dumps({'status':'PASS','commit_count':len(records),'sizes_px':sizes,'records':records},indent=2))
        print(f'PASS live geometry and screenshot sizes: {output}')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
