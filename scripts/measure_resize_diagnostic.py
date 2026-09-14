#!/usr/bin/env python3
"""Fixed 30s warmup + 90s diagnostic. Never a replacement for formal budgets."""
import argparse,csv,json,os,statistics,subprocess,time
from pathlib import Path
from datetime import datetime,timezone
from analyze_performance import p95,presentation_intervals

parser=argparse.ArgumentParser()
parser.add_argument('--binary',type=Path,required=True)
parser.add_argument('--label',required=True)
parser.add_argument('--stages',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
out=root/'docs/evidence'/('UP-02-diagnostic-'+args.label+'-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
out.mkdir()
fixture=(root/'.build/GlassFrameFixture.app/Contents/MacOS/GlassFrameFixture').resolve()
env={k:os.environ[k] for k in ['HOME','USER','LOGNAME','PATH','TMPDIR','LANG','__CF_USER_TEXT_ENCODING'] if k in os.environ}
if args.stages:env['GLASS_CPU_DIAGNOSTICS']='1'
processes=[];handles=[]
def launch(command,name):
    handle=(out/name).open('w');handles.append(handle)
    process=subprocess.Popen(command,stdout=handle,stderr=subprocess.STDOUT,env=env)
    processes.append(process);return process
result={'status':'RUNNING_DIAGNOSTIC_ONLY','binary':str(args.binary.resolve()),'stages_enabled':args.stages}
power=subprocess.Popen(['/usr/bin/caffeinate','-di','-w',str(os.getpid())])
try:
    launch([str(fixture),'--large','--animate','--duration','140'],'fixture.log');time.sleep(1)
    app=launch([str(args.binary),'--test-corner','--resize-performance','--duration','123','--output',str(out)],'process.log')
    began=time.monotonic();report=30;shot=False
    while app.poll() is None:
        elapsed=time.monotonic()-began
        if elapsed>140:raise RuntimeError('Diagnostic timeout')
        file=out/'runtime-latest.json'
        if file.exists():
            state=json.loads(file.read_text())
            if state.get('desktop_blockers') or state.get('pause_reasons') or state['state'] in ['failed','permission_required','desktop_unavailable']:
                raise RuntimeError('Desktop or capture unavailable')
        if elapsed>=20 and not shot:
            ready=json.loads((out/'ready.json').read_text())
            subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(ready['window_number']),str(out/'window.png')],check=True)
            shot=True
        if elapsed>=report:print(args.label,int(elapsed),'/123s',flush=True);report+=30
        time.sleep(.5)
    assert app.returncode==0
    with (out/'samples.csv').open() as f:samples=[r for r in csv.DictReader(f) if 30<=float(r['elapsed_seconds'])<120]
    assert len(samples)==90,len(samples)
    start=json.loads((out/'ready.json').read_text())['measurement_start_uptime']
    with (out/'frames.csv').open() as f:frames=[r for r in csv.DictReader(f) if start+30<=float(r['captured_seconds'])<start+120]
    shown=[r for r in frames if float(r['presented_seconds'])>0]
    counts=[sum(start+30+i<=float(r['presented_seconds'])<start+31+i for r in shown) for i in range(90)]
    result.update(status='DIAGNOSTIC_ONLY',sample_count=len(samples),cpu_median_percent=statistics.median(float(r['cpu_percent_one_core']) for r in samples),
        cpu_mean_percent=statistics.mean(float(r['cpu_percent_one_core']) for r in samples),
        resident_median_mib=statistics.median(float(r['resident_bytes'])/2**20 for r in samples),
        fps_median=statistics.median(counts),interval_p95_ms=p95(presentation_intervals([r['presented_seconds'] for r in shown])),
        gpu_p95_ms=p95([float(r['gpu_ms']) for r in frames]),latency_max_ms=max(float(r['latency_ms']) for r in shown),
        geometry_records=len(list(out.glob('geometry-*.json'))),gpu_samples=len(frames),positive_presentations=len(shown))
    if args.stages:assert json.loads((out/'cpu-stages.json').read_text())['overflow']==0
except BaseException as error:
    result.update(status='INCOMPLETE',error=str(error));raise
finally:
    for process in processes:
        if process.poll() is None:process.terminate();process.wait(timeout=15)
    for handle in handles:handle.close()
    if power.poll() is None:power.terminate();power.wait(timeout=5)
    (out/'result.json').write_text(json.dumps(result,indent=2))
    print(out,flush=True)
