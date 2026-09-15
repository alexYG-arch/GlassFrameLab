#!/usr/bin/env python3
"""Preview three optical rim candidates; do not edit the production default or package an app."""
import json, os, shlex, subprocess, tempfile, time
from pathlib import Path
from PIL import Image, ImageDraw
from material_test_support import ROOT, FIXTURE, wait_json, srgb
run=Path(tempfile.mkdtemp(prefix='glass-rim-optics-',dir='/private/tmp'))
print('RUN',run,flush=True)
source=(ROOT/'Sources/GlassFrameLab/StaticGlassRim.swift').read_text()
assert "distance + 0.55" in source, "Historical preview requires the pre-v1.9 0.55 pt rim; use check_material_rim.py for the current product"
needle='let alpha = UInt8(((outer - inner) * 0.40 * 255).rounded())'
assert source.count(needle)==1, 'Production rim changed; review preview patch'
# Leave three tangent-sigma widths before the stretchable center. Otherwise
# a bright pixel near the tangent is stretched across the entire straight edge.
source=source.replace('let cap = Int(ceil(max(radius, 0.55) * scale)) + 1', 'let cap = Int(ceil(max(radius, 0.55) * scale)) + 16')
source=source.replace('let edgeRows = Int(ceil(0.55 * scale + 0.5))','let edgeRows = Int(ceil(0.55 * scale + 3))')
source=source.replace('let geometry = Geometry(size: imageSize, scale: scale, radius: radius)', 'let variant = ProcessInfo.processInfo.environment["RIM_VARIANT"] ?? "base"\n        let geometry = Geometry(size: imageSize, scale: scale, radius: radius)')
source=source.replace(needle,'''// Experimental optical parameters, never written into the production class.
                let compensate = variant == "compensation" || variant == "combined"
                let soften = variant == "soft" || variant == "combined"
                // Smooth, symmetric correction around arc/straight tangencies,
                // including a short part of the adjoining straight edge.
                let tangentDistance = min(abs(qx), abs(qy)) * scale
                let tangentWeight = max(qx, qy) > radius * 0.7
                    ? exp(-0.5 * pow(tangentDistance / 5.0, 2)) : 0
                let gain = compensate ? 1 + 0.30 * tangentWeight : 1
                let core = (outer - inner) * 0.40 * gain * (soften ? 0.90 : 1)
                // Inward-only subpixel glow; no extra outer ring or new full-window blur.
                let soft = soften ? 0.12 * exp(-0.5 * pow((distance + 0.275) * scale / 0.85, 2)) * outer : 0
                let alpha = UInt8((min(1, core + soft * (1-core)) * 255).rounded())''')
(run/'StaticGlassRim.swift').write_text(source)
objects=[shlex.split(line)[0] for line in (ROOT/'.build/arm64-apple-macosx/release/GlassFrameLab.product/Objects.LinkFileList').read_text().splitlines() if '/LabSupport.build/' in line]
subprocess.run(['swiftc','-O','-module-cache-path',str(ROOT/'.build/clang-cache'),'-I',str(ROOT/'.build/arm64-apple-macosx/release/Modules'),str(run/'StaticGlassRim.swift'),str(ROOT/'Sources/GlassFrameLab/FramePanel.swift'),str(ROOT/'Tests/Fixtures/RimOpticsPreview.swift'),*objects,'-o',str(run/'Preview')],check=True)
pictures=[]
for theme in ['dark','light']:
    back=subprocess.Popen([str(FIXTURE),'--large','--background','dark' if theme=='dark' else 'white','--duration','25'],stdout=subprocess.DEVNULL)
    try:
        time.sleep(.4)
        for variant in ['base','compensation','soft','combined']:
            name=theme+'-'+variant; ready=run/(name+'.json')
            proc=subprocess.Popen([str(run/'Preview')],env={**os.environ,'RIM_THEME':theme,'RIM_VARIANT':variant,'RIM_READY':str(ready)})
            try:
                info=wait_json(ready);time.sleep(.65)
                path=run/(name+'.png')
                subprocess.run(['screencapture','-x','-R',info['rect'],str(path)],check=True)
                pictures.append((name,srgb(path)))
                print('CAPTURED',name,flush=True)
            finally:
                if proc.poll() is None:proc.terminate()
                proc.wait(timeout=5)
    finally:
        if back.poll() is None:back.terminate()
        back.wait(timeout=5)
labels={'base':'0  Current','compensation':'A  Local brightness +30% max','soft':'B  Narrow soft transition','combined':'C  A + B'}
for theme in ['dark','light']:
    selected=[(n,im) for n,im in pictures if n.startswith(theme)]
    sheet=Image.new('RGB',(824,4*152),(32,32,32));d=ImageDraw.Draw(sheet)
    zoom=Image.new('RGB',(4*352,276),(32,32,32));z=ImageDraw.Draw(zoom)
    for i,(name,im) in enumerate(selected):
        label=labels[name[len(theme)+1:]]
        d.text((6,i*152+5),label,fill='white');sheet.paste(im,(0,i*152+28))
        z.text((i*352+4,5),label,fill='white')
        zoom.paste(im.crop((0,0,88,62)).resize((352,248),Image.Resampling.NEAREST),(i*352,28))
    sheet.save(run/(theme+'-native.png'));zoom.save(run/(theme+'-corner-4x.png'))
(run/'parameters.json').write_text(json.dumps({'scope':'preview_only_not_product_default','line_width_pt':0.55,'base_alpha':0.4,'compensation_max_gain':1.30,'tangent_sigma_px':5,'soft_core_multiplier':0.9,'soft_peak_alpha':0.12,'soft_sigma_px':0.85,'rss_test':False,'tangent_fade_padding_px':16},indent=2))
print('FINISHED',run,flush=True)
