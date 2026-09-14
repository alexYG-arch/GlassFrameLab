#!/usr/bin/env python3
"""Consolidate completed same-build engineering measurements; not a review/acceptance vote."""
import json,sys
from pathlib import Path
run=Path(sys.argv[1]).resolve()
record=json.loads((run/'result.json').read_text())
assert record['status']=='CHECKS_PASS_REVIEW_REQUIRED','Native verification is incomplete'
paths={p['name']:Path(p['evidence']) for p in record['phases']}
core=json.loads((paths['core_budget']/'result.json').read_text())
checks=dict(core['checks']);metrics=dict(core['results'])
for kind in ['drag','resize']:
 data=json.loads((paths[kind+'_budget']/'result.json').read_text())
 assert data['binary']==record['binary'] and not data['quick']
 checks.update({kind+'_'+key:value for key,value in data['checks'].items()})
 metrics[kind]=data['metrics']
 checks[kind+'_memory_delta']=data['metrics']['resident_median_mib']-metrics['baseline']['resident_median_mib']<=128
maxcase=paths['maximum_cycles']/'cycles'
before=json.loads((maxcase/'runtime-hidden-baseline.json').read_text())
after=json.loads((maxcase/'runtime-hidden-final.json').read_text())
checks['maximum_hidden_recovery']=after['resident_bytes']-before['resident_bytes']<=10*2**20 and after['retained_buffers']==0 and after['gpu_in_flight']==0
metrics['maximum_hidden']={'memory_after_twenty_cycles_delta_mib':(after['resident_bytes']-before['resident_bytes'])/2**20,
                          'visible_restore_screenshots':len(list(maxcase.glob('restore-*.png')))}
resources={}
for name in ['static','dynamic','large'] + (['effects_off'] if 'effects_off' in metrics else []):
 case=paths['core_budget']/name
 state=json.loads((case/'runtime-latest.json').read_text())
 ready=json.loads((case/'ready.json').read_text())
 w,h=state['buffer_width_px'],state['buffer_height_px']
 resources[name]={'body_pixels':ready['content_size_px'],'panel_pixels':ready['panel_size_px'],
  'capture_pixels':[w,h],'capture_bgra_payload_mib':w*h*4/2**20,
  'blur_bucket_pixels':[((w+63)//64)*64,((h+63)//64)*64],
  'intermediate_textures_in_use':state['intermediate_textures'],'texture_allocations':state['texture_allocations'],
  'capture_queue_depth':state['queue_depth'],'retained_latest_buffers':state['retained_buffers']}
result={'status':'BUDGET_PASS' if all(checks.values()) else 'FINDINGS','binary':record['binary'],
 'sources':{k:str(v) for k,v in paths.items()},'checks':checks,'metrics':metrics,'resources':resources,
 'notes':['Requires independent workpack review and visual inspection.',
          'Static/restore visibility is checked with native screenshots; zero drawable timestamps are never counted as presentations.',
          'CAMetalLayer uses the SDK-documented default drawable pool limit of three; actual system allocation and IOSurface pool occupancy are not inferred from app texture counts.',
          'Raw BGRA payload excludes IOSurface alignment, framework caches and system GPU memory.',
          'CPU/GPU times and work counts are energy proxies, not watts.',
          'Same-build effect on/off measurements are included; differences include run-to-run noise.' if 'effects_off' in metrics else 'Formal effect on/off comparison and final product acceptance belong to WP-09.']}
if 'effects_off' in metrics:
 result['effect_cost_same_drawable']=core['effect_cost_same_drawable']
 result['checks']['effects_off_measurement_complete']=metrics['effects_off']['sample_count']>=295 and metrics['effects_off']['presented_frames']>0
 result['status']='BUDGET_PASS' if all(result['checks'].values()) else 'FINDINGS'
(run/'budget-consolidated.json').write_text(json.dumps(result,indent=2))
print(run/'budget-consolidated.json')
raise SystemExit(0 if all(checks.values()) else 1)
