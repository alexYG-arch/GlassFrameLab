#!/usr/bin/env python3
import json, subprocess, time
from pathlib import Path
from datetime import datetime, timezone

root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('WP-06-style-updates-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
history=[]
with (out/'fixture.log').open('w') as f, (out/'process.log').open('w') as log:
    bg=subprocess.Popen([str(fixture),'--large','--background','white','--duration','25'],stdout=f,stderr=subprocess.STDOUT)
    p=None
    try:
        time.sleep(.5)
        p=subprocess.Popen([str(binary),'--test-corner','--style-probe','--duration','13','--output',str(out)],stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+20
        while p.poll() is None:
            if time.monotonic()>deadline:raise RuntimeError('style update timeout')
            path=out/'runtime-latest.json'
            if path.exists():
                state=json.loads(path.read_text())
                if not history or state!=history[-1]:history.append(state)
            time.sleep(.1)
        assert p.returncode==0
        final=history[-1]
        assert final['style_revision']==final['rendered_style_revision']==3,final
        assert final['gpu_submissions']==4 and final['blur_encodes']==1,final
        assert final['texture_allocations']==1 and final['target_capture_fps']==15,final
        assert final['dropped_metric_records']==0 and not final['error'],final
        assert {s['style_revision'] for s in history}=={0,1,2,3}
        (out/'result.json').write_text(json.dumps({'status':'PASS','binary':str(binary),'fixture':str(fixture),'history':history,
            'timing_note':'This probe reuses a static captured image; its frame latency includes image age and is not used for dynamic capture latency budgets.'},indent=2))
        print('PASS three style updates, four GPU submissions, one blur:',out,flush=True)
    finally:
        if p is not None and p.poll() is None:p.terminate();p.wait(timeout=10)
        if bg.poll() is None:bg.terminate();bg.wait(timeout=10)
