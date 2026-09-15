#!/usr/bin/env python3
"""Production transparent overlay GPU checks; not a native-material visual acceptance."""
import json,shlex,subprocess,tempfile
from pathlib import Path
from PIL import Image,ImageChops,ImageDraw
root=Path(__file__).resolve().parents[1]
run=Path(tempfile.mkdtemp(prefix='glass-system-flow-gpu-',dir='/private/tmp'))
print('RUN',run,flush=True)
s=(root/'Sources/GlassFrameLab/SystemFlowRenderer.swift').read_text().split('static let shader = """')[1]
a,b=s.split('""" + BorderFlowShader.source + """')
f=(root/'Sources/GlassFrameLab/BorderFlowShader.swift').read_text().split('static let source = """')[1].split('"""')[0]
(run/'overlay.metal').write_text(a+f+b.split('"""')[0])
objects=[shlex.split(l)[0] for l in (root/'.build/arm64-apple-macosx/release/GlassFrameLab.product/Objects.LinkFileList').read_text().splitlines() if '/LabSupport.build/' in l]
subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(root/'.build/clang-cache'),'-I',str(root/'.build/arm64-apple-macosx/release/Modules'),str(root/'Tests/Fixtures/SystemFlowRenderCheck.swift'),*objects,'-o',str(run/'check')],check=True)
subprocess.run([str(run/'check'),str(run)],check=True)
def im(mode,light,phase):return Image.frombytes('RGBA',(824,124),(run/f'{mode}-{light:.1f}-{phase:.3f}.bgra').read_bytes(),'raw','BGRA')
checks={};phases=[0,.30,.435,.485,.52,.935,.985]
for phase in phases:
 full=im('full',1,phase);spill=im('spill',1,phase);line=im('line',1,phase)
 assert full.tobytes()==spill.tobytes(),('light line leakage',phase)
 assert not line.getbbox(),('light line only not transparent',phase)
 for light in [0,.5,1]:
  off=im('off',light,phase);assert not off.getbbox()
  pic=im('full',light,phase);alpha=pic.getchannel('A')
  assert alpha.getextrema()[1]>10
  assert all(max(p[:3])<=p[3]+1 for p in pic.getdata()),('invalid premultiplication',phase,light)
  assert all(alpha.crop(box).getextrema()[1]==0 for box in [(0,0,824,9),(0,115,824,124),(0,0,9,124),(815,0,824,124)]),('clipped outer edge',phase,light)
 assert im('full',0,phase).tobytes()!=im('spill',0,phase).tobytes(),('dark line missing',phase)
checks['seven_phases_light_spill_only_dark_line_and_spill']=True
checks['disabled_all_transparent']=True;checks['encoded_rgb_never_exceeds_alpha']=True;checks['outer_margin_clear']=True
alpha=im('full',1,.30).getchannel('A');profile=[alpha.getpixel((520,y)) for y in range(10,62)]
fwhm=sum(v>=max(profile)*.5 for v in profile)
assert fwhm>=8,('mapping resembles thin inner line',profile)
checks['light_mapping_fwhm_px']=fwhm
sheet=Image.new('RGB',(824,2*7*144),(255,255,255));draw=ImageDraw.Draw(sheet)
for i,(light,phase) in enumerate([(l,p) for l in [1,0] for p in phases]):
 pic=im('full',light,phase)
 # Stored GPU bytes are already premultiplied; composite directly, not alpha_composite twice.
 bg=255 if light else 20
 pixels=[tuple(round(p[c]+bg*(1-p[3]/255)) for c in range(3)) for p in pic.getdata()]
 rgb=Image.new('RGB',pic.size);rgb.putdata(pixels)
 draw.text((8,i*144+2),f'light={light} phase={phase}',fill=(0,0,0));sheet.paste(rgb,(0,i*144+20))
sheet.save(run/'contact.png')
(run/'result.json').write_text(json.dumps({'checks':checks,'scope':'overlay_GPU_only'},indent=2))
print(json.dumps(checks),flush=True);print('FINISHED',run,flush=True)
