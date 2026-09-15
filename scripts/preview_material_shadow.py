#!/usr/bin/env python3
"""Finite shadow diagnosis on the actual material; production source is unchanged."""
import json, os, shlex, subprocess, tempfile, time
from pathlib import Path
from PIL import Image, ImageDraw
from material_test_support import ROOT, FIXTURE, wait_json, srgb

run = Path(tempfile.mkdtemp(prefix='glass-shadow-', dir='/private/tmp'))
print('RUN', run, flush=True)
subprocess.run(['swiftc', '-module-cache-path', str(ROOT/'.build/clang-cache'),
    str(ROOT/'Tests/Fixtures/MaterialShadowProbe.swift'), '-o', str(run/'ShadowProbe')], check=True)
subprocess.run([str(run/'ShadowProbe'), str(run)], check=True)
probe = {alpha: [Image.open(run/('caster-'+alpha+'.png')).getpixel((412,y))[3]
    for y in range(13)] for alpha in ['0.04','1.0']}
(run/'caster-alpha.json').write_text(json.dumps(probe, indent=2))
source = (ROOT/'Sources/GlassFrameLab/FramePanel.swift').read_text()
assert "private var systemShadow" not in source, "Historical diagnosis requires pre-v1.9 FramePanel; use check_material_rim.py for the restored shadow"
start = source.index('            NSGraphicsContext.saveGraphicsState()', source.index('override func draw('))
end = source.index('            return', start)
original = source[start:end]
source = source[:start] + '''
            let variant = ProcessInfo.processInfo.environment["RIM_VARIANT"] ?? "current"
            if variant == "independent" {
                // Diagnostic only: preserve the 4% interior backing, but generate
                // the OUTSIDE shadow with a fully opaque temporary caster.
                // Erase that caster before compositing; no opaque plate survives.
                let scale = window?.backingScaleFactor ?? 1
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(bounds.width*scale), pixelsHigh: Int(bounds.height*scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
                bitmap.size = bounds.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                let context = NSGraphicsContext.current!.cgContext
                let shadow = NSShadow()
                shadow.shadowOffset = .zero
                shadow.shadowBlurRadius = (window as? FramePanel)?.shadowInset ?? 6
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
                shadow.set()
                NSColor.black.setFill()
                path.fill()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.setBlendMode(.clear)
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                let image = NSImage(size: bounds.size)
                image.addRepresentation(bitmap)
                image.draw(in: bounds)
                NSColor.black.withAlphaComponent(0.04).setFill()
                path.fill()
            } else {
''' + original.replace('withAlphaComponent(0.14)', 'withAlphaComponent(variant == "off" ? 0 : 0.14)') + '''
            }
''' + source[end:]
(run/'FramePanel.swift').write_text(source)
objects = [shlex.split(line)[0] for line in (ROOT/'.build/arm64-apple-macosx/release/GlassFrameLab.product/Objects.LinkFileList').read_text().splitlines() if '/LabSupport.build/' in line]
subprocess.run(['swiftc', '-O', '-module-cache-path', str(ROOT/'.build/clang-cache'),
    '-I', str(ROOT/'.build/arm64-apple-macosx/release/Modules'),
    str(ROOT/'Sources/GlassFrameLab/StaticGlassRim.swift'), str(run/'FramePanel.swift'),
    str(ROOT/'Tests/Fixtures/RimOpticsPreview.swift'), *objects, '-o', str(run/'Preview')], check=True)

labels = {'current': 'A Current shadow / caster alpha 4%', 'off': 'B Shadow off / same white rim',
          'independent': 'C Independent outer shadow / same white rim'}
metrics = {}
for theme in ['light', 'dark']:
    pictures = {}
    back = subprocess.Popen([str(FIXTURE), '--large', '--background', 'white' if theme == 'light' else 'dark', '--duration', '25'], stdout=subprocess.DEVNULL)
    try:
        time.sleep(.4)
        for variant in labels:
            ready = run/(theme+'-'+variant+'.json')
            proc = subprocess.Popen([str(run/'Preview')], env={**os.environ,
                'RIM_THEME': theme, 'RIM_VARIANT': variant, 'RIM_READY': str(ready)})
            try:
                info = wait_json(ready); time.sleep(.65)
                path = run/(theme+'-'+variant+'.png')
                subprocess.run(['screencapture', '-x', '-R', info['rect'], str(path)], check=True)
                pictures[variant] = srgb(path)
                print('CAPTURED', theme, variant, flush=True)
            finally:
                if proc.poll() is None: proc.terminate()
                proc.wait(timeout=5)
    finally:
        if back.poll() is None: back.terminate()
        back.wait(timeout=5)
    sheet = Image.new('RGB', (824, 3*152), (32,32,32)); draw = ImageDraw.Draw(sheet)
    zoom = Image.new('RGB', (3*352, 276), (32,32,32)); z = ImageDraw.Draw(zoom)
    for i, (variant, label) in enumerate(labels.items()):
        im = pictures[variant]
        draw.text((6,i*152+5), label, fill='white'); sheet.paste(im, (0,i*152+28))
        z.text((i*352+4,5), variant, fill='white')
        zoom.paste(im.crop((0,0,88,62)).resize((352,248), Image.Resampling.NEAREST), (i*352,28))
        # Outside the glass on the top straight edge. sRGB code values only.
        metrics[theme+'-'+variant] = [round(sum(im.getpixel((x,y))[0] for x in range(200,624))/424, 3) for y in range(12)]
    sheet.save(run/(theme+'-native.png')); zoom.save(run/(theme+'-corner-4x.png'))
(run/'metrics.json').write_text(json.dumps({'top_outside_red_by_row': metrics,
    'scope': 'preview_only', 'white_rim': {'width_pt': .55, 'alpha': .40},
    'shadow': {'blur_pt': 6, 'color_alpha': .14, 'offset': [0,0]},
    'rss_test': False}, indent=2))
print('FINISHED', run, flush=True)
