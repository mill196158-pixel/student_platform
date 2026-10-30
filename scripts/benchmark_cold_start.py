"""Benchmark emulator-5554 cold processes without clearing app/account data.

Usage: python scripts/benchmark_cold_start.py <label>
Stop builds/tests before measuring. Only timing markers are exported.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("--disable-impeller", action="store_true",
                        help="Diagnostic intent override only; does not alter the APK")
    args = parser.parse_args()
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789-_"
    if not args.label or any(c not in allowed for c in args.label):
        parser.error("Use lowercase letters, digits, hyphens or underscores")

    adb = Path(os.environ["LOCALAPPDATA"]) / "Android/Sdk/platform-tools/adb.exe"
    device = [str(adb), "-s", "emulator-5554"]
    output = Path("C:/student_platform_e2e") / f"cold-{args.label}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    renderer_args = ["--ez", "enable-impeller", "false"] if args.disable_impeller else []
    for index in range(3):
        launch = subprocess.check_output(
            device + ["shell", "am", "start", "-S", "-W", "-n",
                      "com.mill453020.studentplatform/.MainActivity",
                      "--ez", "startupTrace", "true"] + renderer_args,
            text=True, timeout=40,
        )
        if "Status: ok" not in launch:
            raise RuntimeError(f"Activity did not start: {launch}")
        pid = subprocess.check_output(
            device + ["shell", "pidof", "com.mill453020.studentplatform"],
            text=True, timeout=10,
        ).strip()
        markers = []
        for _ in range(20):
            logs = subprocess.check_output(
                device + ["logcat", "-d", f"--pid={pid}", "-s", "flutter", "StartupTrace"],
                text=True, errors="replace", timeout=10,
            )
            tags = ("[startup-perf]", "[home-perf]", "StartupTrace:")
            markers = [line for line in logs.splitlines()
                       if any(tag in line for tag in tags)]
            if any("[home-perf]" in line for line in markers):
                break
            time.sleep(1)
        row = {"run": index + 1, "launch": launch, "markers": markers}
        rows.append(row)
        output.write_text(json.dumps(rows, ensure_ascii=False, indent=2), "utf-8")
        print(json.dumps(row, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
