#!/usr/bin/env python3
"""Check actual default window backing dimensions and save a native window screenshot."""
import json
import re
import struct
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / "docs/evidence" / f"WP-01-frame-{stamp}"
output.mkdir(parents=True, exist_ok=False)
binary = root / "build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab"
with (output / "process.log").open("w") as log:
    process = subprocess.Popen([str(binary), "--duration", "8", "--output", str(output)], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 10
        while not (output / "ready.json").exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"Frame failed to become ready: {output}")
            time.sleep(0.1)
        ready = json.loads((output / "ready.json").read_text())
        actual = [float(x) for x in re.findall(r'[\d.]+', ready["content_size_px"])]
        assert actual == [800, 100], f"Expected 800x100 display pixels, got {actual}"
        assert ready["mode"] == "frame_carrier" and not ready["screen_capture_enabled"]
        time.sleep(1)
        target = output / "window.png"
        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(ready["window_number"]), str(target)], check=True)
        data = target.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        dimensions = struct.unpack('>II', data[16:24])
        assert dimensions == (800, 100), f"Native screenshot includes unexpected dimensions: {dimensions}"
        process.wait(timeout=15)
        assert process.returncode == 0
        (output / "result.json").write_text(json.dumps({
            "status": "PASS", "window_size_px": actual, "screenshot_size_px": dimensions,
            "source": "actual application ready data and native window screenshot",
            "scope": "WP-01 window carrier; no glass blur or ScreenCaptureKit implemented"
        }, indent=2))
        print(f"PASS actual frame and screenshot: 800x100 px; {output}")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
