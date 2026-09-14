#!/usr/bin/env python3
"""Serial final same-build evidence. PASS here is not a product review vote."""
import json,os,subprocess,sys
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1];evidence=root/'docs/evidence'
out=evidence/('WP-09-verification-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
status={'status':'RUNNING','binary':str(binary),'phases':[]}
def save():(out/'result.json').write_text(json.dumps(status,indent=2))
def run(name,script,prefix,*args):
 assert (root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()==binary
 before=set(evidence.glob(prefix+'*'));phase={'name':name,'status':'RUNNING'};status['phases'].append(phase);save()
 print('START '+name,flush=True)
 completed=subprocess.run([sys.executable,str(root/'scripts'/script),*map(str,args)],cwd=root)
 created=set(evidence.glob(prefix+'*'))-before
 if len(created)==1:phase['evidence']=str(created.pop())
 if completed.returncode:phase['status']='FAILED_OR_BLOCKED';save();raise RuntimeError(name+' did not pass')
 case=Path(phase['evidence'])
 if (case/'result.json').exists():
  measured=json.loads((case/'result.json').read_text()).get('status')
  if measured not in ['PASS','STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED']:
   phase['status']=measured;save();raise RuntimeError(name+': '+str(measured))
 phase['status']='PASS';save();return case
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
try:
 run('resize_budget','check_motion_performance.py','WP-07-resize-','--resize')
 cycles=run('static_and_default_cycles','check_runtime_smoke.py','WP-06-runtime-')/'cycles'
 run('maximum_cycles','check_runtime_smoke.py','WP-06-runtime-','--large')
 run('core_budget','measure_glass_performance.py','WP-06-performance-',cycles)
 run('drag_budget','check_motion_performance.py','WP-07-drag-')
 run('visual_matrix','check_glass_style.py','WP-06-visual-')
 run('realtime_contexts','check_final_contexts.py','WP-09-context-')
 status['status']='CHECKS_PASS_REVIEW_REQUIRED';save()
except BaseException as error:
 status['status']='INCOMPLETE';status['error']=str(error);save();raise
finally:
 if power.poll() is None:power.terminate();power.wait(timeout=5)
 print(out,flush=True)
