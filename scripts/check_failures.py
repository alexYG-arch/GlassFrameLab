#!/usr/bin/env python3
"""Integration checks: invalid inputs and evidence-write failures must not pass."""
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
binary = root / "build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab"
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / "docs/evidence" / f"WP-00-failures-{stamp}"
output.mkdir(parents=True, exist_ok=False)
reuse = output / "reused-evidence"
reuse.mkdir()
(reuse / "samples.csv").write_text("existing evidence\n")
startup = output / "startup-write-error"
startup.mkdir()
(startup / "environment.json").mkdir()  # A directory cannot be overwritten by environment JSON.

cases = [
    ("invalid_duration", ["--duration", "0"]),
    ("existing_evidence", ["--baseline", "--duration", "1", "--output", str(reuse)]),
    ("startup_write_error", ["--baseline", "--duration", "1", "--output", str(startup)]),
]
results = []
for name, flags in cases:
    run = subprocess.run([str(binary), *flags], capture_output=True, text=True, timeout=10)
    results.append({"name": name, "exit_code": run.returncode, "stderr": run.stderr})
    if run.returncode != 2:
        raise RuntimeError(f"{name} expected 2, got {run.returncode}: {run.stderr}")
assert (reuse / "samples.csv").read_text() == "existing evidence\n"
termination = json.loads((startup / "termination.json").read_text())
assert termination["event"] == "application_failed" and termination["exit_status"] == 2
(output / "results.json").write_text(json.dumps(results, indent=2))
print(f"3/3 failure-path checks passed: {output}")
