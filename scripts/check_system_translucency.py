#!/usr/bin/env python3
"""Sparse icon/detail backgrounds; real composited screenshots, not a visibility-only gate."""
import argparse, json, subprocess, tempfile, time
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageStat
from material_test_support import *

parser = argparse.ArgumentParser()
parser.add_argument('--reference-app', type=Path, help='Optional previous HUD app for aligned visual comparison')
args = parser.parse_args()
run = Path(tempfile.mkdtemp(prefix='glass-system-translucency-', dir='/private/tmp'))
print('RUN', run, flush=True)
app = make_test_app(run)
cases = [('light-base', 'light', False), ('light-flow', 'light', True),
         ('dark-base', 'dark', False), ('dark-flow', 'dark', True)]
if args.reference_app:
    cases.insert(0, ('previous-hud-light', 'light', False))
pictures, results = [], []
for name, theme, flow in cases:
    case = run/name; case.mkdir()
    back = None; pid = None
    try:
        back = subprocess.Popen([str(FIXTURE), '--large', '--background',
            'light-detail' if theme == 'light' else 'dark-detail-icons', '--duration', '12'], stdout=subprocess.DEVNULL)
        time.sleep(.6)
        target = args.reference_app if name.startswith('previous') else app
        permission = launch_system(target, case, theme, duration=6,
            extra=['--border-flow', '--test-static-flow'] if flow else [])
        pid = permission['pid']
        time.sleep(1)
        state = wait_json(case/'runtime-latest.json')
        assert not state['reduce_transparency'] and not state['desktop_blockers'], state
        if not name.startswith('previous'):
            assert state['native_material'] == 'glass_clear', state
        assert state['flow_visible'] == flow and state['capture_service_initializations'] == 0, state
        im = screenshot(case)
        assert im.size == (824, 124), im.size
        pictures.append((name, im))
        results.append({'case': name, 'state': state, 'permission': permission,
            # Descriptive only: spatial variation is not visual acceptance.
            'interior_rgb_stddev': ImageStat.Stat(im.crop((80,40,744,84))).stddev})
        wait_json(case/'termination.json')
        print('CAPTURED', name, flush=True)
    finally:
        stop_pid(pid)
        if back and back.poll() is None:
            back.terminate(); back.wait(timeout=5)
by_name = dict(pictures)
flow_differences = {}
for theme in ['light', 'dark']:
    difference = ImageChops.difference(by_name[theme+'-base'], by_name[theme+'-flow'])
    flow_differences[theme] = ImageStat.Stat(difference).mean
    # Catch an overlay hidden by native compositing despite flow_visible=true.
    # This only requires a visible pixel change; quality still needs image review.
    assert max(high for low, high in difference.getextrema()) > 8, theme+' flow lost in compositor'
sheet = Image.new('RGB', (824, 156*len(pictures)), (35,35,35))
draw = ImageDraw.Draw(sheet)
for i, (name, im) in enumerate(pictures):
    draw.text((12,i*156+5), name, fill='white'); sheet.paste(im, (0,i*156+28))
sheet.save(run/'contact.png')
(run/'result.json').write_text(json.dumps({'scope': 'macOS26_actual_sparse_detail_visual_review_required',
    'flow_on_off_rgb_mean_difference': flow_differences, 'cases': results}, indent=2))
print('FINISHED', run, flush=True)
