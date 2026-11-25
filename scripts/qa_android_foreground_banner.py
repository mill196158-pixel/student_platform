"""Run before sending a marker from a second test account to an open Android app."""

import argparse
import re
import subprocess

from android_qa_probe import install_probe, probe_command, require_observation
from qa_android_background_push_materials import Device


def start_banner_probe(device, marker, action):
    if action not in {"tap", "dismiss", "absent"} or not re.fullmatch(r"[A-Za-z0-9_-]{1,120}", marker):
        raise ValueError("Use a single synthetic ASCII marker and a supported banner action")
    jar = "ordinary-foreground-banner.jar"
    cls = "qa.ordinary.ForegroundBannerProbe"
    command = probe_command(jar, cls + "#testBanner", "-e", "marker", marker, "-e", "action", action)
    return subprocess.Popen([*device.prefix, *command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def install_banner_probe(device):
    install_probe(device, "qa.ordinary.ForegroundBannerProbe", "ordinary-foreground-banner.jar")


def finish_banner_probe(process, action):
    try:
        result = process.communicate(timeout=45)[0]
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise
    if process.returncode:
        raise RuntimeError("Android UIAutomator exited unsuccessfully")
    require_observation(result, "observed banner " + action)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    parser.add_argument("action", choices=["tap", "dismiss", "absent"])
    parser.add_argument("marker")
    args = parser.parse_args()
    dev = Device(args.serial)
    install_banner_probe(dev)
    print("Android observer starting", flush=True)
    output = finish_banner_probe(start_banner_probe(dev, args.marker, args.action), args.action)
    print(output.decode(errors="replace"))
