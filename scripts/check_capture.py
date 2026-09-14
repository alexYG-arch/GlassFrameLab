#!/usr/bin/env python3
"""Real ScreenCaptureKit crop, own-app exclusion and hidden-stop checks."""
import io
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from PIL import Image, ImageCms

root = Path(__file__).resolve().parents[1]
output = root/'docs/evidence'/('WP-03-capture-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
output.mkdir(parents=True, exist_ok=False)
binary = root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab'
with (output/'process.log').open('w') as log:
    process = subprocess.Popen([str(binary),'--capture-probe','--duration','8','--output',str(output)],stdout=log,stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic()+20
        captured = False
        while process.poll() is None:
            if time.monotonic()>deadline: raise RuntimeError('Capture probe timeout')
            marker = output/'capture-marker.json'
            if marker.exists() and not captured:
                info=json.loads(marker.read_text())
                subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(info['marker_window_number']),str(output/'marker.png')],check=True)
                captured=True
            time.sleep(.1)
        assert process.returncode==0
        start=json.loads((output/'capture-start.json').read_text())
        if start['state']=='permission_required':
            raise RuntimeError('BLOCKED_VERIFICATION: screen recording permission required')
        active=json.loads((output/'capture-marker-active.json').read_text())
        hidden=[json.loads((output/f'capture-hidden-{n}.json').read_text()) for n in (1,2)]
        assert active['state']=='capturing' and active['received_complete_frames']>0
        assert [active['buffer_width_px'],active['buffer_height_px']]==[472,122]
        assert active['retained_buffers']==1
        assert all(h['state']=='stopped' and h['retained_buffers']==0 for h in hidden)
        assert hidden[0]['received_complete_frames']==hidden[1]['received_complete_frames']
        def magenta_ratio(path):
            im=Image.open(path)
            if 'icc_profile' in im.info:
                im=ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(io.BytesIO(im.info['icc_profile'])),ImageCms.createProfile('sRGB'),outputMode='RGB')
            else:
                im=im.convert('RGB')
            return sum(r>240 and g<15 and b>240 for r,g,b in im.get_flattened_data())/(im.width*im.height)
        marker_ratio=magenta_ratio(output/'marker.png')
        sample_ratio=magenta_ratio(output/'capture-excluding-own-app.png')
        assert marker_ratio>.98, marker_ratio
        assert sample_ratio<.01, sample_ratio
        result={'status':'PASS','active':active,'hidden':hidden,'marker_magenta_ratio':marker_ratio,'captured_magenta_ratio':sample_ratio}
        (output/'result.json').write_text(json.dumps(result,indent=2))
        print(f'PASS real local capture, own-app exclusion and hidden stop: {output}')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
