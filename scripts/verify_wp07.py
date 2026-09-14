#!/usr/bin/env python3
"""Run the remaining WP-07 native checks serially on one immutable build."""
import argparse,json,subprocess,sys
from pathlib import Path
from datetime import datetime,timezone
parser=argparse.ArgumentParser()
parser.add_argument('--completed-resize',type=Path,help='Reuse an already completed full resize measurement of this exact binary')
options=parser.parse_args()
root=Path(__file__).resolve().parents[1]
evidence=root/'docs/evidence'
out=evidence/('WP-07-verification-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir()
binary=(root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()
status={'status':'RUNNING','binary':str(binary),'phases':[]}
def save(): (out/'result.json').write_text(json.dumps(status,indent=2))
def run(name,script,prefix,*args):
 assert (root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()==binary,'Build changed during verification'
 before=set(evidence.glob(prefix+'*'))
 phase={'name':name,'status':'RUNNING'};status['phases'].append(phase);save()
 print('START '+name,flush=True)
 result=subprocess.run([sys.executable,str(root/'scripts'/script),*map(str,args)],cwd=root)
 created=set(evidence.glob(prefix+'*'))-before
 if len(created)==1:phase['evidence']=str(created.pop())
 if result.returncode:
  phase['status']='FAILED_OR_BLOCKED';save();raise RuntimeError(name+' did not pass')
 case=Path(phase['evidence'])
 if (case/'result.json').exists():
  measured=json.loads((case/'result.json').read_text()).get('status')
  if measured not in ['PASS','STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED']:
   phase['status']=measured;save();raise RuntimeError(name+': '+str(measured))
 phase['status']='PASS';save();return case
try:
 run('motion_and_interruption','check_motion.py','WP-07-motion-')
 run('style_cache','check_style_updates.py','WP-06-style-updates-')
 cycles=run('static_and_default_cycles','check_runtime_smoke.py','WP-06-runtime-')/'cycles'
 run('maximum_cycles','check_runtime_smoke.py','WP-06-runtime-','--large')
 run('core_budget','measure_glass_performance.py','WP-06-performance-',cycles,'--core-only')
 run('drag_budget','check_motion_performance.py','WP-07-drag-')
 if options.completed_resize:
  case=options.completed_resize.resolve()
  measured=json.loads((case/'result.json').read_text())
  assert measured['status']=='PASS' and not measured['quick'] and measured['kind']=='resize'
  assert measured['binary']==str(binary),'Cannot reuse another binary'
  assert measured['metrics']['sample_count']>=295 and all(measured['checks'].values())
  status['phases'].append({'name':'resize_budget','status':'PASS','evidence':str(case),'reused_completed_measurement':True})
  save()
 else:
  run('resize_budget','check_motion_performance.py','WP-07-resize-','--resize')
 status['status']='CHECKS_PASS_REVIEW_REQUIRED';save()
except BaseException as error:
 status['status']='INCOMPLETE';status['error']=str(error);save();raise
finally:print(out,flush=True)
