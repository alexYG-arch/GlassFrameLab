#!/usr/bin/env python3
"""Read retained measurements; never substitute draw calls for presentations."""
import csv,json,math,statistics,sys
from decimal import Decimal
from pathlib import Path

def rows(path):
    with path.open() as f: return list(csv.DictReader(f))
def p95(values):
    return sorted(values)[math.ceil(len(values)*.95)-1] if values else None
def presentation_intervals(values):
    # CSV timestamps have nine decimal places. Subtract before converting to
    # float so a 50 ms interval is not inflated by large-uptime cancellation.
    times=sorted(Decimal(value) for value in values)
    return [float((b-a)*1000) for a,b in zip(times,times[1:])]

def analyze(case,large=False):
    samples=[r for r in rows(case/'samples.csv') if 30<=float(r['elapsed_seconds'])<330 and float(r['interval_seconds'])>.5]
    assert len(samples)>=295, f'Incomplete five-minute samples: {case} ({len(samples)})'
    t=[float(r['elapsed_seconds'])/60 for r in samples]
    m=[float(r['resident_bytes'])/2**20 for r in samples]
    tm,mm=statistics.mean(t),statistics.mean(m)
    slope=sum((x-tm)*(y-mm) for x,y in zip(t,m))/sum((x-tm)**2 for x in t)
    delta=statistics.median(y for x,y in zip(t,m) if x>=4.5)-statistics.median(y for x,y in zip(t,m) if x<1.5)
    result={'cpu_median_percent':statistics.median(float(r['cpu_percent_one_core']) for r in samples),'resident_median_mib':statistics.median(m),'memory_slope_mib_per_minute':slope,'memory_last_minus_first_minute_mib':delta,'sample_count':len(samples)}
    ready=json.loads((case/'ready.json').read_text())
    start=ready['measurement_start_uptime']
    frames=[r for r in rows(case/'frames.csv') if start+30<=float(r['captured_seconds'])<start+330]
    shown=[r for r in frames if float(r['presented_seconds'])>0]
    times=sorted(float(r['presented_seconds']) for r in shown)
    counts=[sum(start+30+i<=v<start+31+i for v in times) for i in range(300)]
    result.update({'gpu_p95_ms':p95([float(r['gpu_ms']) for r in frames]),'gpu_sample_count':len(frames),'presented_frames':len(shown),'unpresented_drawables':len(frames)-len(shown),'fps_median':statistics.median(counts),'presentation_interval_p95_ms':p95(presentation_intervals([r['presented_seconds'] for r in shown])),'latency_p95_ms':p95([float(r['latency_ms']) for r in shown]),'latency_max_ms':max((float(r['latency_ms']) for r in shown),default=None),'actual_size_px':ready['content_size_px']})
    runtime=rows(case/'runtime-samples.csv')
    if runtime:
        assert all(int(r['in_flight'])<=1 and int(r['retained_buffers'])<=1 for r in runtime)
        result['texture_allocations']=max(int(r['texture_allocations']) for r in runtime)
        final=json.loads((case/'runtime-latest.json').read_text())
        assert final['dropped_metric_records']==0,'Presentation log overflow invalidates measurement'
    return result

if __name__=='__main__':
    root=Path(sys.argv[1]);results={}
    for name in ['baseline','static','dynamic','large']:
        results[name]=analyze(root/name,name=='large')
    if (root/'effects_off').exists():
        results['effects_off']=analyze(root/'effects_off')
    checks={}
    baseline=results['baseline']
    for name in ['static','dynamic','large']:
        r=results[name]
        checks[name+'_memory_stable']=r['memory_slope_mib_per_minute']<=1 and r['memory_last_minus_first_minute_mib']<=5
        if name!='large':checks[name+'_memory_delta']=r['resident_median_mib']-baseline['resident_median_mib']<=128
    checks['static_cpu']=results['static']['cpu_median_percent']<=3
    static_state=json.loads((root/'static/runtime-latest.json').read_text())
    checks['static_no_repeat_render']=results['static']['gpu_sample_count']==0 and static_state['gpu_submissions']==1 and static_state['blur_encodes']==1
    d=results['dynamic']
    checks.update({'dynamic_cpu':d['cpu_median_percent']<=15,'dynamic_gpu':d['gpu_p95_ms'] is not None and d['gpu_p95_ms']<=12,'dynamic_fps':27<=d['fps_median']<=30,'dynamic_frame_interval':d['presentation_interval_p95_ms'] is not None and d['presentation_interval_p95_ms']<=50,'dynamic_latency':d['latency_p95_ms'] is not None and d['latency_p95_ms']<=100 and d['latency_max_ms']<=250})
    if len(sys.argv)>2:
        cycles=Path(sys.argv[2])
        hidden=[r for r in rows(cycles/'samples.csv') if float(r['elapsed_seconds'])>=98 and float(r['interval_seconds'])>.5]
        before=json.loads((cycles/'runtime-hidden-baseline.json').read_text());after=json.loads((cycles/'runtime-hidden-final.json').read_text())
        cpu=statistics.median(float(r['cpu_percent_one_core']) for r in hidden)
        delta=(after['resident_bytes']-before['resident_bytes'])/2**20
        results['hidden']={'cpu_median_percent':cpu,'memory_after_twenty_cycles_delta_mib':delta,'sample_count':len(hidden),'evidence':str(cycles)}
        checks['hidden_cpu']=cpu<=baseline['cpu_median_percent']+.5
        checks['hidden_recovery']=delta<=10 and after['retained_buffers']==0 and after['gpu_in_flight']==0
        checks['twenty_restores_rendered']=after['gpu_submissions']-before['gpu_submissions']>=20
    else: checks['hidden_evidence_available']=False
    result={'status':'PASS' if all(checks.values()) else 'FINDINGS','results':results,'checks':checks,'notes':['Presentation statistics use positive MTLDrawable.presentedTime only. The legacy unpresented_drawables field counts zero timestamps; zero alone does not establish visual invisibility, which is checked separately by native screenshots.','GPU P95 in a perfectly static steady state is not applicable because no duplicate commands are submitted.','CPU and work counts are energy proxies, not watts.','The baseline runs concurrently with the static test; it has no window or capture.']}
    if 'effects_off' in results:
        on,off=results['dynamic'],results['effects_off']
        result['effect_cost_same_drawable']={key:on[key]-off[key] for key in ['cpu_median_percent','resident_median_mib','gpu_p95_ms']}
        result['effect_cost_same_drawable']['note']='Same build and drawable envelope; subtraction includes run-to-run noise. Outer padding area is 27.72% above the old 800x100 drawable and is not removed in this shader-only A/B.'
    (root/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
