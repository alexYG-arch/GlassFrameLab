#!/usr/bin/env python3
"""Run the WP-00 app, collect baseline evidence, and capture only its test window."""
import argparse
import csv
import json
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab"


def summarize(directory):
    with (directory / "samples.csv").open() as file:
        rows = list(csv.DictReader(file))
    # Omit initialization and the potentially partial final interval.
    steady = [row for row in rows if float(row["elapsed_seconds"]) >= 5 and float(row["interval_seconds"]) >= 0.8]
    if not steady:
        raise RuntimeError(f"No complete steady intervals: {directory}")
    memory = [int(row["resident_bytes"]) / 2**20 for row in steady if row["resident_bytes"]]
    cpu = [float(row["cpu_percent_one_core"]) for row in steady]
    draws = [float(row["draw_calls_per_second"]) for row in steady]
    return {
        "sample_count": len(rows), "steady_sample_count": len(steady),
        "resident_mib_min": min(memory) if memory else None,
        "resident_mib_max": max(memory) if memory else None,
        "resident_mib_median": statistics.median(memory) if memory else None,
        "cpu_percent_one_core_median": statistics.median(cpu),
        "cpu_percent_one_core_max": max(cpu),
        "draw_calls_per_second_median": statistics.median(draws),
        "draw_calls_per_second_min": min(draws),
        "draw_calls_per_second_max": max(draws),
    }


def run_case(root, name, flags, duration, screenshot=False):
    directory = root / name
    directory.mkdir()
    command = [str(BINARY), *flags, "--duration", str(duration), "--output", str(directory)]
    (directory / "command.json").write_text(json.dumps(command, indent=2))
    screenshot_results = []
    with (directory / "process.log").open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while not (directory / "ready.json").exists():
                if process.poll() is not None:
                    raise RuntimeError(f"App exited before ready: {directory}")
                if time.monotonic() > deadline:
                    raise RuntimeError(f"App did not become ready: {directory}")
                time.sleep(0.1)
            if screenshot:
                ready = json.loads((directory / "ready.json").read_text())
                window_id = ready["window_number"]
                if window_id <= 0:
                    raise RuntimeError("No native window ID available for screenshot")
                time.sleep(2)
                for index in (1, 2):
                    target = directory / f"window-{index}.png"
                    capture = subprocess.run(
                        ["/usr/sbin/screencapture", "-x", "-o", "-l", str(window_id), str(target)],
                        capture_output=True, text=True, timeout=10,
                    )
                    screenshot_results.append({
                        "source": "macOS screencapture of actual app window",
                        "window_id": window_id, "exit_code": capture.returncode,
                        "stderr": capture.stderr, "file": target.name,
                        "exists": target.exists(),
                    })
                    time.sleep(0.3)
                (directory / "screenshot-results.json").write_text(json.dumps(screenshot_results, indent=2))
            process.wait(timeout=duration + 20)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    if process.returncode != 0 or not (directory / "termination.json").exists():
        raise RuntimeError(f"Missing clean exit evidence: {directory}")
    result = summarize(directory)
    result["process_exit_code"] = process.returncode
    if screenshot:
        result["native_screenshots_captured"] = all(item["exit_code"] == 0 and item["exists"] for item in screenshot_results)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root = args.output or ROOT / "docs/evidence" / f"WP-00-{stamp}"
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=False)
    (root / "power-source.txt").write_text(subprocess.run(
        ["/usr/bin/pmset", "-g", "batt"], capture_output=True, text=True, check=True).stdout)
    summary = {
        "baseline": run_case(root, "baseline", ["--baseline"], 15),
        "static": run_case(root, "static", ["--calibration"], 15, screenshot=True),
        "animated": run_case(root, "animated", ["--animate"], 20),
        "limitations": [
            "Short WP-00 calibration only; not a five-minute glass stability test",
            "AppKit draw counts are not GPU presentation or capture FPS",
            "No GPU duration or watts measured",
        ],
    }
    if summary["baseline"]["resident_mib_median"] is not None and summary["static"]["resident_mib_median"] is not None:
        summary["static_minus_baseline_resident_mib"] = summary["static"]["resident_mib_median"] - summary["baseline"]["resident_mib_median"]
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    print(root)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
