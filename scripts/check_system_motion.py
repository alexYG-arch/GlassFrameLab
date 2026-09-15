#!/usr/bin/env python3
"""Short geometry-only follow-up, screenshot times anchored to the in-app probe clock."""
import json,subprocess,tempfile,time
from pathlib import Path
from PIL import Image,ImageDraw
from material_test_support import *
run=Path(tempfile.mkdtemp(prefix='glass-system-motion-',dir='/private/tmp'));print('RUN',run,flush=True)
app=make_test_app(run);case=run/'motion';case.mkdir();back=None;pid=None;images=[];rows=[]
try:
 back=subprocess.Popen([str(FIXTURE),'--large','--background','dark','--duration','18'],stdout=subprocess.DEVNULL)
 time.sleep(.4)
 permission=launch_system(app,case,'dark',duration=14,extra=['--border-flow','--motion-probe'])
 pid=permission['pid'];anchor=wait_json(case/'motion-probe-start.json')['uptime']
 for target in [1.5,2.05,3.15,3.4,4.65,6.2,7.15,9.5,10.25,11.5]:
  while time.monotonic()<anchor+target:time.sleep(.015)
  geometry=wait_json(case/'geometry-latest.json')
  im=screenshot(case,f'motion-{target}');images.append((f'{target}s {geometry["actual_size_px"]}',im))
  rows.append({'time':target,'geometry':geometry,'image_size':im.size})
 wait_json(case/'termination.json',timeout=8)
 final=wait_json(case/'motion-settled.json')
 assert final['material_visible'] and final['flow_running'] and final['capture_service_initializations']==0,final
 assert len({tuple(r['image_size']) for r in rows})>=4,rows
 result={'scope':'real_native_geometry_screenshots_not_resource_repeat','permission':permission,'frames':rows,'settled':final}
 (run/'result.json').write_text(json.dumps(result,indent=2))
 width=max(im.width for _,im in images);height=sum(im.height+26 for _,im in images)
 sheet=Image.new('RGB',(width,height),(36,36,36));draw=ImageDraw.Draw(sheet);y=0
 for label,im in images:draw.text((8,y+5),label,fill='white');sheet.paste(im,(0,y+26));y+=im.height+26
 sheet.save(run/'contact.png');print('FINISHED',run,flush=True)
finally:
 stop_pid(pid)
 if back and back.poll() is None:back.terminate();back.wait(timeout=5)
