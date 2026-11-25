"""Check the contents of a DWG exported from the student chat on Android.

Install the offline CADView Community preview 3 and the student QA fixture on
a Student_CAD_QA_ AVD. Save a known drawing from the chat to Downloads. Run
this check once per revision, using a label inside the drawing, for example:
python scripts/qa_android_dwg_viewer.py emulator-5578 qa-first.dwg "QA SHEET 1 - ACADEMIC FLOOR" build/cad-qa
The Android file picker and viewer are driven through their UIs. The screenshot
and a transcript from Windows' local OCR are saved in the output directory.
"""
import argparse
import hashlib
import re
import subprocess
import time
from pathlib import Path

from qa_android_background_push_materials import Device


VIEWER = "org.cadview.cad_view.community"
VIEWER_ACTIVITY = VIEWER + "/org.cadview.cad_view.MainActivity"


def words(text):
    return " ".join(re.findall(r"[\w]+", text.casefold()))


def validate_export(device, filename, expected_sha):
    if not re.fullmatch(r"[a-zA-Z0-9_-]+\.[dD][wW][gG]", filename):
        raise ValueError("Use a distinct, shell-safe QA export filename")
    data = device.run("exec-out", "cat", "/sdcard/Download/" + filename)
    digest = hashlib.sha256(data).hexdigest()
    if not data.startswith(b"AC10") or (expected_sha and digest != expected_sha.lower()):
        raise RuntimeError("Unexpected DWG in Downloads")
    return digest


def choose_in_downloads(device, filename):
    resolved = device.run("shell", "cmd", "package", "resolve-activity", "--brief",
                          "-a", "android.intent.action.VIEW_DOWNLOADS").decode()
    package = resolved.strip().splitlines()[-1].split("/")[0]
    if not package.endswith(".documentsui"):
        raise RuntimeError("Android DocumentsUI is required on the test image")
    device.run("shell", "am", "force-stop", VIEWER)
    device.run("shell", "am", "start", "-a", "android.intent.action.MAIN",
               "-c", "android.intent.category.LAUNCHER", "-n", VIEWER_ACTIVITY)
    device.tap("Open drawing", package=VIEWER, wait=40)
    try:
        row = device.find(filename, package=package, wait=5)
    except RuntimeError:
        device.tap("Show roots", package=package)
        device.tap("Downloads", package=package)
        row = device.find(filename, package=package)
    device.tap_node(row)


def verify_render(device, filename, expected, output):
    screenshot = output / (filename + ".png")
    transcript = output / (filename + ".txt")
    ocr = Path(__file__).with_name("android_qa") / "read_screen_ocr.ps1"
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        activities = device.run("shell", "dumpsys", "activity", "activities").decode(errors="replace")
        if not any(VIEWER + "/" in line and "topResumedActivity=" in line
                   for line in activities.splitlines()):
            time.sleep(0.4)
            continue
        screenshot.write_bytes(device.run("exec-out", "screencap", "-p"))
        result = subprocess.run(["powershell.exe", "-NoProfile", "-File", str(ocr), str(screenshot)],
                                check=True, encoding="utf-8", capture_output=True, timeout=20)
        transcript.write_text(result.stdout, encoding="utf-8")
        if f" {words(expected)} " in f" {words(result.stdout)} ":
            return
        time.sleep(0.5)
    raise RuntimeError(f"CAD model label missing on the viewer screen. See {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    parser.add_argument("filename")
    parser.add_argument("model_text")
    parser.add_argument("output", type=Path)
    parser.add_argument("--sha256", help="SHA-256 of the original CAD fixture")
    args = parser.parse_args()
    if not words(args.model_text) or words(args.model_text) in words(args.filename):
        raise ValueError("Expected text must identify model content independently of the filename")
    device = Device(args.serial, avd_prefix="Student_CAD_QA_")
    digest = validate_export(device, args.filename, args.sha256)
    args.output.mkdir(parents=True, exist_ok=True)
    choose_in_downloads(device, args.filename)
    verify_render(device, args.filename, args.model_text, args.output.resolve())
    print(f"PASS {args.filename}: {digest}; CAD model label: {args.model_text}")


if __name__ == "__main__":
    main()
