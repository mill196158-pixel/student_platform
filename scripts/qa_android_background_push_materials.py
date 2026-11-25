"""Drive the two Android E2E fixtures on a dedicated QA emulator.

Install integration_test/android_background_push_fixture_main.dart first.
Use prepare with an ACL-protected dir containing android.json. Send two FCM
messages to its fcm-token.txt using the two IDs from the local test backend,
then run read. Install the materials fixture and run materials on the same AVD.
"""

import argparse
import json
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = "com.mill453020.studentplatform.offlinefixture"
ACTIVITY = PACKAGE + "/com.mill453020.studentplatform.MainActivity"


class Device:
    def __init__(self, serial):
        if not re.fullmatch(r"emulator-\d+", serial):
            raise ValueError("Choose the dedicated QA emulator")
        self.prefix = ["adb", "-s", serial]
        name = self.run("emu", "avd", "name").decode().splitlines()[0].strip()
        if not name.startswith("Student_Push_Materials_QA_"):
            raise ValueError("Expected a dedicated, disposable QA AVD")
        if PACKAGE.encode() not in self.run("shell", "pm", "list", "packages", PACKAGE):
            raise ValueError("Install the isolated fixture first")

    def run(self, *args, **kwargs):
        return subprocess.check_output(
            [*self.prefix, *args], timeout=25, stderr=subprocess.DEVNULL, **kwargs
        )

    def start(self):
        self.run("shell", "am", "start", "-n", ACTIVITY)

    def write_private(self, name, data):
        subprocess.run(
            [*self.prefix, "shell", "-T", "run-as", PACKAGE, "tee", "files/" + name],
            input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15, check=True,
        )

    def nodes(self):
        path = "/data/local/tmp/student-materials-push-qa.xml"
        self.run("shell", "uiautomator", "dump", path)
        raw = self.run("exec-out", "cat", path)
        start, end = raw.find(b"<hierarchy"), raw.rfind(b"</hierarchy>")
        if start < 0 or end < start:
            return []
        hierarchy = ET.fromstring(raw[start : end + len(b"</hierarchy>")])
        return [n for n in hierarchy.iter("node") if n.get("package") == PACKAGE]

    def find(self, label, *, wait=18, scroll=False):
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                nodes = self.nodes()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                time.sleep(0.5)
                continue
            for n in nodes:
                text = n.get("content-desc") or n.get("text") or ""
                if label in text.splitlines():
                    return n
            if scroll:
                self.run("shell", "input", "swipe", "500", "1770", "500", "670", "300")
            time.sleep(0.25)
        raise RuntimeError(f"Expected fixture control unavailable: {label}")

    def tap(self, label, **kwargs):
        n = self.find(label, **kwargs)
        x, y, xx, yy = map(int, re.findall(r"\d+", n.get("bounds")))
        self.run("shell", "input", "tap", str((x + xx) // 2), str((y + yy) // 2))

    def notification_ids(self, recipient):
        keys = self.run("shell", "cmd", "notification", "list").decode().splitlines()
        ids = set()
        for key in keys:
            parts = key.strip().split("|")
            if len(parts) > 3 and parts[1] == PACKAGE:
                prefix = "student:" + recipient + ":"
                if parts[3].startswith(prefix):
                    ids.add(parts[3][len(prefix) :])
        return ids

    def expect_ids(self, recipient, expected, timeout=60, observed=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            current = self.notification_ids(recipient)
            if observed is not None:
                current &= observed
            if current == expected:
                return
            time.sleep(0.6)
        raise RuntimeError("Expected set of OS notifications did not appear")


def prepare(device, private, cfg):
    port = cfg["port"]
    if type(port) != int or not 1024 <= port <= 65535:
        raise ValueError("Invalid test port")
    device.run("reverse", f"tcp:{port}", f"tcp:{port}")
    device.run("shell", "pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS")
    device.start()
    device.run("shell", "run-as", PACKAGE, "mkdir", "-p", "files")
    local_cfg = {key: cfg[key] for key in ("port", "anonKey", "email", "password")}
    device.write_private("student_push_qa_config.json", json.dumps(local_cfg).encode())
    device.find("Firebase ready", wait=150)
    token = device.run("exec-out", "run-as", PACKAGE, "cat", "files/student_push_qa_token").strip()
    if not 40 <= len(token) <= 4096 or any(c <= 32 for c in token):
        raise RuntimeError("Invalid registration response")
    (private / "fcm-token.txt").write_bytes(token)
    device.tap("Sign in to the local test account")
    device.find("Test student signed in")
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    print("PASS local account signed in; recipient is in background", flush=True)


def read(device, cfg):
    owner, first, second = (cfg[k] for k in ("recipientId", "firstId", "secondId"))
    device.expect_ids(owner, {first, second}, timeout=100)
    print("PASS two addressed system notifications visible in background", flush=True)
    device.start()
    device.tap("Open notification center")
    try:
        device.find("QA notice 1", wait=3)
    except RuntimeError:
        device.tap("Ещё 1")
    device.tap("QA notice 1")
    device.expect_ids(owner, {second})
    print("PASS reading first in the real center removed only first from Android", flush=True)


def background(device, cfg, phase, private):
    def check_background():
        activities = device.run("shell", "dumpsys", "activity", "activities").decode()
        resumed = [line for line in activities.splitlines()
                   if "topResumedActivity=" in line or "mResumedActivity:" in line]
        if not resumed or any(PACKAGE in line for line in resumed):
            raise RuntimeError("The test app must remain in background")

    def suppression_count():
        raw = device.run("logcat", "-d", "-s", "StudentPush:D", "*:S")
        return raw.count(b"suppressed_read_display")

    owner, first, second = (cfg[k] for k in ("recipientId", "firstId", "secondId"))
    check_background()
    observed = {first, second}
    device.expect_ids(owner, observed if phase == "pair" else {second}, observed=observed)
    counter = private / "read-display-count.txt"
    if phase == "removed":
        counter.write_text(str(suppression_count()), encoding="ascii")
    if phase == "replay":
        before = int(counter.read_text(encoding="ascii"))
        deadline = time.monotonic() + 60
        while suppression_count() <= before:
            if time.monotonic() >= deadline:
                raise RuntimeError("Android never received the delayed read display")
            time.sleep(0.5)
        device.expect_ids(owner, {second}, observed=observed)
    check_background()
    print(f"PASS Android background notification state: {phase}", flush=True)


def materials(device, cfg=None, ca=None):
    def enter():
        device.tap("База", wait=50)
        device.tap("Предмет для проверки", scroll=True)
        device.tap("Открыть чат", scroll=True)
        device.find("Проверка истории предмета")
        device.tap("Файлы")
        device.tap("Чат")
        device.find("Проверка истории предмета")

    if cfg:
        port = cfg["port"]
        if type(port) != int or not 1024 <= port <= 65535:
            raise ValueError("Invalid test port")
        pem = ca.read_bytes()
        if b"-----BEGIN CERTIFICATE-----" not in pem or b"PRIVATE KEY" in pem:
            raise ValueError("Supply the public test CA certificate")
        device.run("reverse", f"tcp:{port}", f"tcp:{port}")
        device.run("shell", "run-as", PACKAGE, "mkdir", "-p", "files")
        device.write_private("student_materials_qa_ca.pem", pem)
        subset = {k: cfg[k] for k in ("port", "anonKey", "email", "password")}
        device.write_private("student_materials_qa_config.json", json.dumps(subset).encode())
    device.start()
    enter()
    print("PASS subject materials opened its saved team chat; Files → Chat round trip", flush=True)
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")
    device.run("shell", "am", "force-stop", PACKAGE)
    if cfg:
        device.run("reverse", "--remove", f"tcp:{port}")
        device.run("shell", "run-as", PACKAGE, "rm", "files/student_materials_qa_config.json")
    device.start()
    enter()
    print("PASS subject materials reopened the same saved history after process restart", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "read", "materials", "pair", "removed", "replay"])
    parser.add_argument("--serial", required=True)
    parser.add_argument("--private", type=Path)
    parser.add_argument("--config", default="android.json")
    parser.add_argument("--ca", type=Path)
    opts = parser.parse_args()
    device = Device(opts.serial)
    if opts.action == "materials":
        cfg = None
        if opts.ca:
            if not opts.private:
                parser.error("--ca requires --private")
            cfg = json.loads((opts.private / opts.config).read_text(encoding="utf-8-sig"))
        materials(device, cfg, opts.ca)
        return
    if not opts.private:
        parser.error("--private must name the ACL-protected local fixture directory")
    cfg = json.loads((opts.private / opts.config).read_text(encoding="utf-8-sig"))
    if opts.action == "prepare":
        prepare(device, opts.private, cfg)
    elif opts.action == "read":
        read(device, cfg)
    else:
        background(device, cfg, opts.action, opts.private)


if __name__ == "__main__":
    main()
