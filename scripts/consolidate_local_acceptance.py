#!/usr/bin/env python3
"""Combine the frozen build's evidence, preserving the user-accepted RSS failure."""
import json,sys,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve()
load=lambda p:json.loads(p.read_text())
run=load(out/'result.json')
assert run['status']=='CHECKS_COMPLETE_VISUAL_REVIEW_REQUIRED'
assert run['known_issue']=='U02-06' and run['source_diff_equals_F2']
oldroot=root/'docs/evidence/UP-02-verification-20260913T121055Z'
old=load(oldroot/'result.json')
assert old['binary']==run['binary']
paths={p['name']:Path(p['evidence']) for p in old['phases']}
paths.update({p['name']:Path(p['evidence']) for p in run['phases']})
core=load(paths['core_budget']/'result.json')
assert load(paths['core_budget']/'run.json')['binary']==run['binary']
checks=dict(core['checks']);metrics=dict(core['results'])
for kind,phase in [('drag','drag_budget'),('resize','resize_budget'),('resize_confirmation','resize_confirmation_budget')]:
 d=load(paths[phase]/'result.json')
 assert d['binary']==run['binary'] and not d['quick'] and d['status']=='PASS'
 checks.update({kind+'_'+k:v for k,v in d['checks'].items()})
 metrics[kind]=d['metrics']
 checks[kind+'_memory_delta']=d['metrics']['resident_median_mib']-metrics['baseline']['resident_median_mib']<=128
maxcase=paths['maximum_cycles']/'cycles'
before=load(maxcase/'runtime-hidden-baseline.json');after=load(maxcase/'runtime-hidden-final.json')
checks['maximum_hidden_recovery']=after['resident_bytes']-before['resident_bytes']<=10*2**20 and after['retained_buffers']==0 and after['gpu_in_flight']==0
metrics['maximum_hidden']={'memory_after_twenty_cycles_delta_mib':(after['resident_bytes']-before['resident_bytes'])/2**20,'restore_screenshot_count':len(list(maxcase.glob('restore-*.png')))}
checks['effects_off_measurement_complete']=metrics['effects_off']['sample_count']>=295 and metrics['effects_off']['presented_frames']>0
for phase in ['compat_static','compat_dynamic','geometry','motion','style','static_and_default_cycles','maximum_cycles','visual_matrix','realtime_contexts']:
 result_path=paths[phase]/'result.json'
 if phase in ['static_and_default_cycles','maximum_cycles']:result_path=paths[phase]/'cycles/result.json'
 d=load(result_path)
 if phase=='static_and_default_cycles':assert load(paths[phase]/'static/result.json')['status']=='PASS'
 assert d['status'] in ['PASS','STRUCTURAL_PASS_VISUAL_REVIEW_REQUIRED']
 if 'binary' in d:assert d['binary']==run['binary']
 checks[phase+'_engineering']=True
failures=[k for k,v in checks.items() if not v]
assert failures==['large_memory_stable'],failures
resources={}
for name in ['static','dynamic','large','effects_off']:
 p=paths['core_budget']/name;s=load(p/'runtime-latest.json');r=load(p/'ready.json')
 resources[name]={'body_pixels':r['content_size_px'],'panel_pixels':r['panel_size_px'],'capture_pixels':[s['buffer_width_px'],s['buffer_height_px']],'intermediate_textures':s['intermediate_textures'],'texture_allocations':s['texture_allocations'],'queue_depth':s['queue_depth'],'retained_buffers':s['retained_buffers']}
binary=Path(run['binary'])
assert (root/'build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab').resolve()==binary
with zipfile.ZipFile(root/'build/GlassFrameLab.zip') as z:assert z.read('GlassFrameLab.app/Contents/MacOS/GlassFrameLab')==binary.read_bytes()
result={'status':'BUDGET_COMPLETE_WITH_ACCEPTED_DEVIATION','raw_budget_status':'FINDINGS','binary':run['binary'],'checks':checks,'raw_failed_checks':failures,'accepted_deviation':{'id':'U02-06','check':'large_memory_stable','authority':'Explicit user acceptance on 2026-09-13','scope':'Current local build, maximum-size RSS only','record':'docs/本机已知问题.md'},'metrics':metrics,'resources':resources,'effect_cost_same_drawable':core['effect_cost_same_drawable'],'sources':{k:str(v) for k,v in paths.items()},'zip_executable_matches':True,'notes':['Raw RSS failure is retained. Acceptance is not a claim of technical repair.','Prior and new evidence use the same unchanged executable.','CPU and GPU are energy proxies, not watts.','Final visual review is recorded separately.']}
(out/'budget-consolidated.json').write_text(json.dumps(result,indent=2))
print(result['status'],len(checks),'checks;',len(failures),'explicitly accepted deviation')
