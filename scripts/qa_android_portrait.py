"""Test the actual Flutter window while rotating an isolated Android emulator.

Run with the same offline emulator and APK SHA-256 as qa_android_ordinary_guest.
The suite first rotates Android Settings. Then it measures the app Activity and
its rendered view after a landscape cold start and an opposite rotation.
"""

import argparse
import re
import time

from qa_android_ordinary_guest import GuestDevice, PACKAGE, bounds


def shell(device, *args):
    return device.run("shell", *args).decode().strip()


def frame(device):
    state = shell(device, "dumpsys", "window", "displays")
    result = re.search(r"DisplayFrames w=(\d+) h=(\d+) r=(\d+)", state)
    if result is None:
        raise RuntimeError("Android did not report the display frame")
    return tuple(map(int, result.groups()))


def await_turn(device, landscape):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        width, height, rotation = frame(device)
        if (width > height) == landscape:
            return width, height, rotation
        time.sleep(.5)
    raise RuntimeError("Emulated sensor did not turn Android Settings")


def active_config(device, package):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        state = shell(device, "dumpsys", "activity", "activities")
        resumed = re.search(r"topResumedActivity=ActivityRecord\{[^\r\n]*?\bu\d+ ([^/\s]+)/", state)
        if resumed and resumed[1] == package:
            activity_dump = shell(device, "dumpsys", "activity", "top")
            activities = re.findall(r"^  ACTIVITY " + re.escape(package) +
                                    r"/\S+[^\n]*\n(.*?)(?=^  ACTIVITY |\Z)", activity_dump,
                                    re.MULTILINE | re.DOTALL)
            if activities:
                config = re.search(r"mCurrentConfig=([^\r\n]+)", activities[-1])
                if config:
                    return config[1]
        time.sleep(.25)
    raise RuntimeError("Expected a resumed activity with a reported configuration in " + package)


def app_geometry(device):
    config = active_config(device, PACKAGE)
    window = re.search(r"mAppBounds=Rect\((\d+), (\d+) - (\d+), (\d+)\)", config)
    orientation = re.search(r"\b(port|land)\b", config)
    if not window or not orientation:
        raise RuntimeError("Student activity window bounds or orientation unavailable")
    x, y, right, bottom = map(int, window.groups())
    nodes = device.nodes(PACKAGE)
    if not nodes:
        raise RuntimeError("Student Flutter accessibility view is absent")
    view_x, view_y, view_right, view_bottom = bounds(nodes[0])
    return orientation[1], (right-x, bottom-y), (view_right-view_x, view_bottom-view_y)


def require_portrait(device, step):
    kind, (w, h), (vw, vh) = app_geometry(device)
    print(f"{step}: activity={kind} appBounds={w}x{h} view={vw}x{vh} display={frame(device)}", flush=True)
    if kind != "port" or w >= h or vw >= vh:
        raise AssertionError("App content rotated to landscape: " + step)


def exercise(device, form):
    shell(device, "am", "force-stop", PACKAGE)
    shell(device, "am", "start", "-a", "android.settings.SETTINGS")
    device.run("emu", "sensor", "set", "acceleration", "0:9.81:0")
    await_turn(device, False)
    device.run("emu", "sensor", "set", "acceleration", "9.81:0:0")
    display = await_turn(device, True)
    config = active_config(device, "com.android.settings")
    smallest = int(re.search(r"\bsw(\d+)dp\b", config)[1])
    if (smallest >= 600) != (form == "large-screen"):
        raise RuntimeError(f"{form}: unexpected Android smallest width {smallest}dp")
    print(form, "Android Settings rotated to", display, f"sw{smallest}dp", flush=True)
    shell(device, "am", "start", "-n", PACKAGE + "/.MainActivity")
    launch_config = active_config(device, PACKAGE)
    native_orientation = re.search(r"\b(port|land)\b", launch_config)[1]
    native_bounds = re.search(r"mAppBounds=Rect\(([^)]+)\)", launch_config)[1]
    print(f"{form} launch configuration: {native_orientation} bounds {native_bounds}", flush=True)
    device.label("Войти")
    require_portrait(device, form + " cold guest home")
    device.click("Профиль")
    device.label("Гостевой режим")
    device.run("emu", "sensor", "set", "acceleration", "-9.81:0:0")
    # Wait for Android's sensor hysteresis before sampling the app's own window.
    time.sleep(2)
    device.label("Гостевой режим")
    require_portrait(device, form + " guest profile after opposite rotation")
    shell(device, "am", "force-stop", PACKAGE)


def run(device):
    sdk = int(shell(device, "getprop", "ro.build.version.sdk"))
    if sdk < 36:
        raise RuntimeError("Android API 36 or later is required")
    print(f"Orientation test on Android API {sdk}", flush=True)
    density = shell(device, "wm", "density")
    if "Override density" in density:
        raise RuntimeError("Use a fresh QA AVD with its original screen density")
    prior_sensor = device.run("emu", "sensor", "get", "acceleration").decode()
    sensor = re.search(r"acceleration = ([\d:.eE+\-]+)", prior_sensor)[1]
    rotation = shell(device, "settings", "get", "system", "accelerometer_rotation")
    failures = []
    try:
        shell(device, "settings", "put", "system", "accelerometer_rotation", "1")
        for form, dpi in [("phone", None), ("large-screen", "240")]:
            if dpi:
                shell(device, "wm", "density", dpi)
            try:
                exercise(device, form)
            except AssertionError as failure:
                failures.append(str(failure))
    finally:
        shell(device, "am", "force-stop", PACKAGE)
        device.run("emu", "sensor", "set", "acceleration", sensor)
        shell(device, "wm", "density", "reset")
        if rotation == "null":
            shell(device, "settings", "delete", "system", "accelerometer_rotation")
        else:
            shell(device, "settings", "put", "system", "accelerometer_rotation", rotation)
        device.require_offline()
    if failures:
        raise AssertionError("; ".join(failures))
    print("PASS portrait on phone and large-screen Android during cold start and in-app rotation", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    parser.add_argument("sha256")
    args = parser.parse_args()
    run(GuestDevice(args.serial, args.sha256))
