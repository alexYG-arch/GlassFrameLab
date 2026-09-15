#!/usr/bin/env python3
"""Preview wider B, legacy coverage, and light contrast candidates; do not edit the production default or package an app."""
import argparse, json, os, shlex, subprocess, tempfile, time
from pathlib import Path
from PIL import Image, ImageDraw
from material_test_support import ROOT, FIXTURE, wait_json, srgb
parser=argparse.ArgumentParser();parser.add_argument('--theme',choices=['light','dark']);args=parser.parse_args()
themes=[args.theme] if args.theme else ['dark','light']
run=Path(tempfile.mkdtemp(prefix='glass-rim-widths-',dir='/private/tmp'))
print('RUN',run,flush=True)
source=(ROOT/'Sources/GlassFrameLab/StaticGlassRim.swift').read_text()
assert "distance + 0.55" in source, "Historical preview requires the pre-v1.9 0.55 pt rim; use check_material_rim.py for the current product"
needle='let alpha = UInt8(((outer - inner) * 0.40 * 255).rounded())'
assert source.count(needle)==1, 'Production rim changed; review preview patch'
source=source.replace('0.55', 'rimWidth')
source=source.replace('let scale = window?.backingScaleFactor ?? 1', '\n'.join([
    'let configData = (ProcessInfo.processInfo.environment["RIM_SPEC"] ?? "{}").data(using: .utf8)!',
    'let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Double] ?? [:]',
    'let rimWidth = config["width"] ?? 0.55',
    'let opacity = config["opacity"] ?? 0.40',
    'let softGain = config["soft"] ?? 0',
    'let shadeGain = config["shade"] ?? 0',
    'let legacy = config["legacy"] == 1',
    'func smooth(_ lo: CGFloat, _ hi: CGFloat, _ value: CGFloat) -> CGFloat {',
    'let t = max(0, min(1, (value-lo)/(hi-lo))); return t*t*(3-2*t)',
    '}',
    'let scale = window?.backingScaleFactor ?? 1']))
source=source.replace('let edgeRows = Int(ceil(rimWidth * scale + 0.5))','let edgeRows = Int(ceil(rimWidth * scale + 5))')
source=source.replace('let cap = Int(ceil(max(radius, rimWidth) * scale)) + 1','let cap = Int(ceil(max(radius, rimWidth) * scale)) + 4')
source=source.replace(needle, '''// Experimental coverage reuse only, not the captured renderer's complete composite.
                let depth = max(-distance, 0)
                let aa = 1 / scale
                let coverage = legacy
                    ? (1-smooth(-aa,aa,distance)) * (1-smooth(max(0,rimWidth-aa*0.4),rimWidth+aa*0.4,depth))
                    : outer-inner
                let core = coverage * opacity
                let glow = softGain * exp(-0.5 * pow((distance + rimWidth/2) * scale / 0.80, 2)) * outer
                let white = min(1,core + glow * (1-core))
                // Broad monotonic shading under the white edge, not an inset dark stroke.
                let shade = shadeGain * exp(-depth * scale / 1.8) * outer
                let total = white + shade * (1-white)
                let alpha = UInt8((min(1,total) * 255).rounded())
                let whiteByte = UInt8((white * 255).rounded())''')
source=source.replace('for channel in 0..<4 { pixels[offset + channel] = alpha }','for channel in 0..<3 { pixels[offset + channel] = whiteByte }; pixels[offset + 3] = alpha')
(run/'StaticGlassRim.swift').write_text(source)
objects=[shlex.split(line)[0] for line in (ROOT/'.build/arm64-apple-macosx/release/GlassFrameLab.product/Objects.LinkFileList').read_text().splitlines() if '/LabSupport.build/' in line]
subprocess.run(['swiftc','-O','-module-cache-path',str(ROOT/'.build/clang-cache'),'-I',str(ROOT/'.build/arm64-apple-macosx/release/Modules'),str(run/'StaticGlassRim.swift'),str(ROOT/'Sources/GlassFrameLab/FramePanel.swift'),str(ROOT/'Tests/Fixtures/RimOpticsPreview.swift'),*objects,'-o',str(run/'Preview')],check=True)
profiles={
 'current': {'width':0.55,'opacity':0.40},
 'b070': {'width':0.70,'opacity':0.36,'soft':0.08},
 'b085': {'width':0.85,'opacity':0.36,'soft':0.08},
 'legacy055': {'width':0.55,'opacity':0.40,'legacy':1},
 'legacy070': {'width':0.70,'opacity':0.40,'legacy':1},
 'white070': {'width':0.70,'opacity':0.65,'soft':0.08},
 'white070shade': {'width':0.70,'opacity':0.65,'soft':0.08,'shade':0.08},
 'legacy070shade': {'width':0.70,'opacity':0.65,'legacy':1,'shade':0.08}
}
labels={'current':'0 Current 0.55 pt','b070':'B1 0.70 pt + soft','b085':'B2 0.85 pt + soft','legacy055':'L1 Legacy coverage 0.55 pt','legacy070':'L2 Legacy coverage 0.70 pt','white070':'W White stronger / B1','white070shade':'S White + subtle dark support / B1','legacy070shade':'LS White + dark support / legacy 0.70'}
pictures=[]
for theme in themes:
    back=subprocess.Popen([str(FIXTURE),'--large','--background','dark' if theme=='dark' else 'white','--duration','40'],stdout=subprocess.DEVNULL)
    try:
        time.sleep(.4)
        for variant in (['current','b070','b085','legacy055','legacy070'] if theme=='dark' else ['current','b070','b085','white070','white070shade','legacy070shade']):
            name=theme+'-'+variant; ready=run/(name+'.json')
            proc=subprocess.Popen([str(run/'Preview')],env={**os.environ,'RIM_SPEC':json.dumps(profiles[variant]),'RIM_THEME':theme,'RIM_VARIANT':variant,'RIM_READY':str(ready)})
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
for theme in themes:
    selected=[(n,im) for n,im in pictures if n.startswith(theme)]
    sheet=Image.new('RGB',(824,len(selected)*152),(32,32,32));d=ImageDraw.Draw(sheet)
    zoom=Image.new('RGB',(len(selected)*352,276),(32,32,32));z=ImageDraw.Draw(zoom)
    for i,(name,im) in enumerate(selected):
        label=labels[name[len(theme)+1:]]
        d.text((6,i*152+5),label,fill='white');sheet.paste(im,(0,i*152+28))
        z.text((i*352+4,5),label,fill='white')
        zoom.paste(im.crop((0,0,88,62)).resize((352,248),Image.Resampling.NEAREST),(i*352,28))
    sheet.save(run/(theme+'-native.png'));zoom.save(run/(theme+'-corner-4x.png'))
(run/'parameters.json').write_text(json.dumps({'scope':'preview_only_not_product_default','profiles':profiles,'soft_sigma_px':0.80,'shade_falloff_px':1.8,'rss_test':False},indent=2))
print('FINISHED',run,flush=True)
