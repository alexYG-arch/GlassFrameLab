"""Finite native-material test helpers. Test app is temporary, never a release package."""
import json, os, re, plistlib, shutil, signal, subprocess, time
from io import BytesIO
from pathlib import Path
from PIL import Image, ImageCms
ROOT = Path(__file__).resolve().parents[1]
BINARY = (ROOT/'.build/release/GlassFrameLab').resolve()
FIXTURE = ROOT/'.build/GlassFrameFixture'

def make_test_app(run):
    app=run/'GlassFrame Material Test.app'
    contents=app/'Contents'; (contents/'MacOS').mkdir(parents=True)
    shutil.copy2(BINARY,contents/'MacOS/GlassFrameLab')
    info=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())
    info['CFBundleIdentifier']='local.uidev.GlassFrameLab.material'
    info['CFBundleName']='GlassFrame Material Test'
    info.pop('NSScreenCaptureUsageDescription',None)
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    return app

def wait_json(path, timeout=12):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if path.exists(): return json.loads(path.read_text())
        time.sleep(.1)
    raise RuntimeError('Missing '+str(path))

def srgb(path):
    image=Image.open(path)
    profile=image.info.get('icc_profile')
    if profile:
        return ImageCms.profileToProfile(image.convert('RGB'),ImageCms.ImageCmsProfile(BytesIO(profile)),ImageCms.createProfile('sRGB'),outputMode='RGB')
    return image.convert('RGB')

def screenshot(case,name='window'):
    ready=wait_json(case/'ready.json')
    path=case/(name+'.png')
    # A window-only capture omits behindWindow's compositor backdrop. Capture
    # the actual screen rectangle so native blur is included in visual evidence.
    geometry=case/'geometry-latest.json'
    frame=json.loads(geometry.read_text())['frame_pt'] if geometry.exists() else ready['frame_pt']
    x,y,w,h=map(float,re.findall(r'-?[\d.]+',frame))
    env=wait_json(case/'environment.json')
    sx,sy,sw,sh=map(float,re.findall(r'-?[\d.]+',env['screens'][0]['frame_pt']))
    rect=f'{round(x)},{round(sy+sh-y-h)},{round(w)},{round(h)}'
    subprocess.run(['/usr/sbin/screencapture','-x','-R',rect,str(path)],check=True)
    return srgb(path)

def stop_pid(pid):
    if not pid: return
    try: os.kill(pid,signal.SIGTERM)
    except ProcessLookupError: return

def launch_system(app,case,appearance='light',duration=8,extra=()):
    case.mkdir(exist_ok=True)
    args=['--material-backend','system','--duration',str(duration),'--output',str(case),'--test-permission-status']
    if appearance: args+=['--test-appearance',appearance]
    subprocess.run(['open','-n',str(app),'--args',*args,*extra],check=True)
    permission=wait_json(case/'permission-test.json')
    state=wait_json(case/'runtime-latest.json')
    try:
        if state['desktop_blockers']: raise RuntimeError('Desktop unavailable: '+str(state))
        assert state['capture_service_initializations']==0,state
        assert state['material_visible'],state
    except BaseException:
        stop_pid(permission['pid'])
        raise
    return permission
