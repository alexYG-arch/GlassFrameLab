#!/usr/bin/env python3
"""Reuse frozen budgets, additionally require the independent resize confirmation."""
import json,subprocess,sys
from pathlib import Path

run=Path(sys.argv[1]).resolve()
subprocess.run([sys.executable,str(Path(__file__).with_name('consolidate_wp07.py')),str(run)],check=True)
record=json.loads((run/'result.json').read_text())
budget=json.loads((run/'budget-consolidated.json').read_text())
phase=next(p for p in record['phases'] if p['name']=='resize_confirmation_budget')
confirmation=json.loads((Path(phase['evidence'])/'result.json').read_text())
assert confirmation['binary']==record['binary'] and not confirmation['quick']
budget['checks'].update({'resize_confirmation_'+k:v for k,v in confirmation['checks'].items()})
budget['checks']['resize_confirmation_memory_delta']=confirmation['metrics']['resident_median_mib']-budget['metrics']['baseline']['resident_median_mib']<=128
budget['metrics']['resize_confirmation']=confirmation['metrics']
budget['status']='BUDGET_PASS' if all(budget['checks'].values()) else 'FINDINGS'
budget['notes'].append('Both independent formal resize runs must pass separately; their measurements are not averaged to pass.')
(run/'budget-consolidated.json').write_text(json.dumps(budget,indent=2))
print(budget['status'],len(budget['checks']),'checks')
raise SystemExit(0 if budget['status']=='BUDGET_PASS' else 1)
