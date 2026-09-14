#!/usr/bin/env python3
"""Fixed-input actual Metal shader regression, separate from capture/runtime tests."""
import json, subprocess, tempfile, shlex, colorsys, argparse
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--shader-file',type=Path,help='Frozen production shader for same-input candidate comparisons')
parser.add_argument('--light-flow',choices=['spill','line'],default='spill',help='Expected Light treatment; line is for frozen legacy comparisons')
args=parser.parse_args()
objects=[shlex.split(line)[0] for line in (root/'.build/arm64-apple-macosx/release/GlassFrameLab.product/Objects.LinkFileList').read_text().splitlines() if '/LabSupport.build/' in line]
subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(root/'.build/clang-cache'),'-I',str(root/'.build/arm64-apple-macosx/release/Modules'),str(root/'Tests/Fixtures/MaterialRenderCheck.swift'),*objects,'-o',str(root/'.build/MaterialRenderCheck')],check=True)
run=Path(tempfile.mkdtemp(prefix='glass-material-check-',dir='/private/tmp'))
s=(root/'Sources/GlassFrameLab/GlassRenderer.swift').read_text().split('private static let shader = """')[1]
a,b=s.split('""" + BorderFlowShader.source + """')
flow=(root/'Sources/GlassFrameLab/BorderFlowShader.swift').read_text().split('static let source = """')[1].split('"""')[0]
source=args.shader_file.read_text() if args.shader_file else a+flow+b.split('"""')[0]
(run/'current.metal').write_text(source+"\nkernel void checkFlowColors(device const float4* input [[buffer(0)]], device float4* output [[buffer(1)]], uint id [[thread_position_in_grid]]) { output[id] = float4(adaptFlowColor(input[id].rgb,input[id].w),1); }")
(run/'baseline.metal').write_bytes((root/'Tests/Fixtures/GlassShader-pre-adaptive.metal').read_bytes())
subprocess.run([str(root/'.build/MaterialRenderCheck'),str(run)],check=True)
checks={}
color_results=json.loads((run/'flow-colors.json').read_text())
def encode(v):return v*12.92 if v<=.0031308 else 1.055*v**(1/2.4)-.055
for row in color_results:
 a=colorsys.rgb_to_hsv(*map(encode,row['input']))
 b=colorsys.rgb_to_hsv(*map(encode,row['output']))
 assert min(abs(a[0]-b[0]),1-abs(a[0]-b[0]))<.00001,row
 assert b[1]+.00001>=a[1] and b[2]<a[2],row
brand_hsv=colorsys.rgb_to_hsv(59/255,120/255,221/255)
dark_hsv=colorsys.rgb_to_hsv(*map(encode,color_results[0]['input']))
light_hsv=colorsys.rgb_to_hsv(*map(encode,color_results[0]['output']))
previous_dark_hsv=colorsys.rgb_to_hsv(*map(encode,[.12,.85,1]))
assert abs(dark_hsv[0]-brand_hsv[0])<.00001
assert max(abs(dark_hsv[i]-previous_dark_hsv[i]) for i in [1,2])<.00001
assert light_hsv[1]>brand_hsv[1] and light_hsv[2]>brand_hsv[2]
for name in ['white','gray','warm','cool','dark','dark-detail','mixed','pattern']:
 old=Image.open(run/f'{name}-baseline-0.30.png').convert('RGBA')
 off=Image.open(run/f'{name}-adaptive-off-0.30.png').convert('RGBA')
 new=Image.open(run/f'{name}-adaptive-on-0.30.png').convert('RGBA')
 def error(a,b):return max(max(pair) for pair in ImageChops.difference(a,b).getextrema())
 checks[name]={'disabled_max_channel_error':error(old,off),'enabled_max_channel_error':error(old,new)}
 assert checks[name]['disabled_max_channel_error']==0,checks[name]
 if name in ['white','gray']:
  assert error(Image.open(run/f'{name}-flow-0.30.png'),Image.open(run/f'{name}-flow-base-off-0.30.png'))==0
 if name in ['white','gray','warm','cool','mixed','pattern']:assert checks[name]['enabled_max_channel_error']==0,checks[name]
 if name in ['dark','dark-detail']:assert checks[name]['enabled_max_channel_error']>0,checks[name]
# Preserve the previous line-specific checks for frozen comparison shaders.
if args.light_flow=='line':
 # A light-colored rebound between outer diffusion and line caused the visible gap.
 # Sample a fixed straight-edge head in the rendered image, not shader internals.
 edge_checks={}
 for name,background in [('white',(255,255,255)),('gray',(242,242,242))]:
  def composite(file):
   im=Image.open(file).convert('RGBA'); bg=Image.new('RGBA',im.size,background+(255,));bg.alpha_composite(im);return bg.convert('RGB')
  im=composite(run/f'{name}-flow-0.30.png')
  base=composite(run/f'{name}-adaptive-on-0.30.png')
  profile=[sum(c*w for c,w in zip(im.getpixel((534,y)),[.2126,.7152,.0722])) for y in range(4,13)]
  maximum_rebound=max(b-a for a,b in zip(profile,profile[1:]))
  mapping_difference=sum(abs(a-b) for a,b in zip(im.getpixel((534,20)),base.getpixel((534,20))))/3
  assert maximum_rebound<=1,(name,profile)
  # A lower mapping gain is an explicit v1.9 candidate variable. Require a
  # visible signal; review line-versus-spill balance in the isolated render too.
  assert mapping_difference>=10,(name,mapping_difference)
  edge_checks[name]={'outer_to_line_luminance':profile,'maximum_rebound':maximum_rebound,'inward_mapping_difference':mapping_difference}
  # Compare the whole line cross-section at faint ends. Luminance alone
  # incorrectly forced a dark contact stripe over the naturally white base rim.
  # Upper/lower chroma must fade together, without an isolated inward stripe.
  def chroma(x,y):
   pixel=im.getpixel((x,y));return max(pixel)-min(pixel)
  fade_samples={}
  for x in [340,360,380,560,565,570]:
   upper,lower=chroma(x,11),chroma(x,12)
   assert lower>=8 and .60<=upper/lower<=1.05,(name,x,upper,lower)
   fade_samples[x]={'upper_chroma':upper,'lower_chroma':lower}
  head=[chroma(x,12) for x in [560,565,570,575]]
  steps=[a-b for a,b in zip(head,head[1:])]
  assert min(steps)>0,(name,head)
  for x in [595,605,615]:
   assert max(chroma(x,y) for y in [10,11,12,13])<=1,(name,'detached_head',x)
  cross=[chroma(534,y) for y in range(7,18)]
  fwhm=sum(c>=max(cross)*.5 for c in cross)
  assert fwhm<=2,(name,'thick_line',cross)
  purple=im.getpixel((380,12))
  assert purple[0]-purple[1]>=5 and purple[2]-purple[0]>=5,(name,purple)
  blue=im.getpixel((470,12))
  assert blue[1]>blue[0] and blue[2]>blue[1],(name,'purple_too_long',blue)
  edge_checks[name].update({'fade_cross_sections':fade_samples,'head_chroma_steps':steps,
   'line_fwhm_pixels':fwhm,'purple_tail_pixel':purple,'blue_body_pixel':blue})
else:
 # Light now intentionally has no moving line. Assert complete layer identity
 # instead of requiring the old two-pixel colored edge and its cross-section.
 edge_checks={}
 for name in ['white','gray','warm','cool']:
  full=Image.open(run/f'{name}-flow-0.30.png').convert('RGBA')
  spill=Image.open(run/f'{name}-flow-spill-0.30.png').convert('RGBA')
  line=Image.open(run/f'{name}-flow-line-0.30.png').convert('RGBA')
  base=Image.open(run/f'{name}-adaptive-on-0.30.png').convert('RGBA')
  assert error(full,spill)==0,(name,'moving line leaked into Light')
  assert error(line,base)==0,(name,'line-only changed base material')
  for box in [(0,0,824,11),(0,113,824,124),(0,0,11,124),(813,0,824,124)]:
   assert error(full.crop(box),base.crop(box))==0,(name,'exterior flow remains')
  edge_checks[name]={'full_equals_spill':True,'line_only_equals_base':True,'exterior_equals_base':True}
 for name,bg in [('white',(255,255,255)),('gray',(242,242,242))]:
  def composite(mode):
   im=Image.open(run/f'{name}-{mode}-0.30.png').convert('RGBA');back=Image.new('RGBA',im.size,bg+(255,));back.alpha_composite(im);return back.convert('RGB')
  im=composite('flow');base=composite('adaptive-on')
  mapping_difference=sum(abs(a-b) for a,b in zip(im.getpixel((534,20)),base.getpixel((534,20))))/3
  assert mapping_difference>=10,(name,'mapping disappeared',mapping_difference)
  def chroma(x,y):
   px=im.getpixel((x,y));return max(px)-min(px)
  # Follow the full 10 pt (20 px) Gaussian spread beyond two radii; a
  # faint signal at only 1.5 radii is expected, not a hard residual band.
  inward=[chroma(534,y) for y in range(12,62)]
  fwhm=sum(c>=max(inward)*.5 for c in inward)
  assert fwhm>=8,(name,'mapping became a narrow inner line',inward)
  assert max(inward[-8:])<=1,(name,'mapping does not dissipate',inward)
  head=[chroma(x,20) for x in range(550,616,5)]
  assert all(b<=a+1 for a,b in zip(head,head[1:])) and head[0]>head[-1] and head[-1]<=1,(name,'hard or detached mapping head',head)
  purple=im.getpixel((380,18));blue=im.getpixel((470,18))
  assert purple[0]>purple[1] and purple[2]>purple[0],(name,'purple tail missing',purple)
  assert blue[1]>blue[0] and blue[2]>blue[1],(name,'blue body missing',blue)
  edge_checks[name].update({'inward_mapping_difference':mapping_difference,'soft_mapping_fwhm_pixels':fwhm,'head_chroma':head,'purple_mapping_pixel':purple,'blue_mapping_pixel':blue})

results=json.loads((run/'render-results.json').read_text())
for r in results:
 if r['input'] in ['white','gray'] and r['mode']=='adaptive-on':assert r['statistics'][2]==0,r
items=[]
for name in ['white','gray','dark','dark-detail']:
 for mode in ['adaptive-on','flow']:
  im=Image.open(run/f'{name}-{mode}-0.30.png').convert('RGBA')
  color={'white':(255,255,255),'gray':(242,242,242),'dark':(19,23,31),'dark-detail':(10,15,23)}[name]
  bg=Image.new('RGBA',im.size,color+(255,));bg.alpha_composite(im)
  items.append((name+' '+mode,bg.convert('RGB')))
sheet=Image.new('RGB',(824,len(items)*154),(40,40,40));d=ImageDraw.Draw(sheet)
for i,(label,im) in enumerate(items):d.text((8,i*154+8),label,fill='white');sheet.paste(im,(0,i*154+30))
sheet.save(run/'contact.png')
(run/'summary.json').write_text(json.dumps({'scope':'fixed_input_GPU_shader_only','checks':checks,'flow_hue_preserved':True,'flow_independent_of_base_switch':True,'flow_colors':color_results,'light_flow_mode':args.light_flow,'light_edge_checks':edge_checks},indent=2))
print(json.dumps(checks,indent=2));print('RUN',run,flush=True)
