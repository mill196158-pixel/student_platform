"""Compile and validate the app's transient Android UI observers."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def install_probe(device, class_name, jar):
    sdk = Path(shutil.which("adb")).resolve().parents[1]
    platform = sdk / "platforms/android-34"
    libs = [platform / name for name in
            ("android.jar", "uiautomator.jar", "optional/android.test.base.jar")]
    compiler = Path(shutil.which("javac")).resolve()
    env = {**os.environ, "JAVA_HOME": str(compiler.parents[1])}
    source = Path(__file__).parent / "android_qa" / (class_name.rsplit(".", 1)[-1] + ".java")
    d8 = sdk / "build-tools/36.0.0" / ("d8.bat" if os.name == "nt" else "d8")
    with tempfile.TemporaryDirectory() as output:
        dest = Path(output)
        subprocess.run([compiler, "-encoding", "UTF-8", "-source", "8", "-target", "8",
                        "-classpath", os.pathsep.join(map(str, libs)), "-d", dest, source],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        subprocess.run([d8, *[v for lib in libs for v in ("--lib", lib)], "--output",
                        dest / jar, dest / (class_name.replace(".", "/") + ".class")],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        device.run("push", str(dest / jar), "/data/local/tmp/" + jar)


def probe_command(jar, method, *args):
    # Newer Android images make these optional framework classes available
    # only when explicitly included in the legacy UIAutomator classpath.
    return ["shell", "uiautomator", "runtest", "/system/framework/android.test.base.jar",
            "/system/framework/android.test.runner.jar", jar, "-c", method, *args]


def require_observation(result, marker):
    output = result.decode(errors="replace").replace("\r", "")
    if (marker not in output.splitlines()
            or "INSTRUMENTATION_STATUS_CODE: 0" not in output.splitlines()
            or "INSTRUMENTATION_STATUS: shortMsg=" in output
            or not re.search(r"(?m)^OK\s*\(1 test\)$", output)):
        raise RuntimeError("The Android probe did not complete its UI assertion")
