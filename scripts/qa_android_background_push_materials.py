"""Drive the two Android E2E fixtures on a dedicated QA emulator.

Install integration_test/android_background_push_fixture_main.dart first.
Use prepare with an ACL-protected dir containing android.json. Send two FCM
messages to its fcm-token.txt using the two IDs from the local test backend,
then run read. Install the materials fixture and run materials on the same AVD.
For cold-tap and warm-tap, build the push fixture with E2E_COLD_PUSH_TAP=true.
Seed two independent DM histories on the local E2E database, then send both
notices in the background. Run cold-tap before warm-tap on that installation.
"""

import argparse
import json
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from uuid import UUID

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

    def nodes(self, package=PACKAGE):
        path = "/data/local/tmp/student-materials-push-qa.xml"
        self.run("shell", "uiautomator", "dump", path)
        raw = self.run("exec-out", "cat", path)
        start, end = raw.find(b"<hierarchy"), raw.rfind(b"</hierarchy>")
        if start < 0 or end < start:
            return []
        hierarchy = ET.fromstring(raw[start : end + len(b"</hierarchy>")])
        return [n for n in hierarchy.iter("node") if n.get("package") == package]

    def find(self, label, *, wait=18, scroll=False, package=PACKAGE):
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                nodes = self.nodes(package)
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
        self.tap_node(self.find(label, **kwargs))

    def tap_node(self, n):
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


def check_chat_reads(cfg, read_chats):
    owner = UUID(cfg["recipientId"])
    rows = []
    for label in ("first", "second"):
        notice, chat, message = (UUID(cfg[label + k]) for k in ("Id", "ChatId", "MessageId"))
        rows.append(f"('{label}', '{notice}'::uuid, '{chat}'::uuid, '{message}'::uuid)")
    query = f"""
        SELECT f.label, n.read_at IS NOT NULL, COALESCE(r.last_read_message_id = f.message, false)
        FROM (VALUES {', '.join(rows)}) AS f(label, notice, chat, message)
        JOIN public.app_notifications n ON n.id = f.notice AND n.recipient_id = '{owner}'::uuid
        LEFT JOIN public.chat_reads r ON r.chat_id = f.chat AND r.user_id = n.recipient_id
        ORDER BY f.label
    """
    expected = [label + ("|t|t" if label in read_chats else "|f|f") for label in ("first", "second")]
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        result = subprocess.check_output(
            ["docker", "exec", "-i", "supabase_db_student_platform_e2e", "psql",
             "-XAt", "-U", "postgres", "-v", "ON_ERROR_STOP=1"],
            input=query, text=True, timeout=8,
        )
        if result.splitlines() == expected:
            return
        time.sleep(0.5)
    raise RuntimeError("The server's notification read state or DM read cursor did not match")


def tap_system_card(device, title, body, tag):
    def last_click():
        events = device.run("logcat", "-b", "events", "-d", "-v", "epoch",
                            "-s", "notification_clicked:I").decode()
        clicks = [line for line in events.splitlines() if "|" + PACKAGE + "|" in line]
        return clicks[-1] if clicks else ""

    def resource(node):
        return node.get("resource-id", "").split("/")[-1]

    def contains(row, label):
        return any(label in (n.get("content-desc") or n.get("text") or "").splitlines()
                   for n in row.iter("node"))

    previous = last_click()
    device.run("shell", "cmd", "statusbar", "expand-notifications")
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        rows = [n for n in device.nodes("com.android.systemui") if resource(n) == "expandableNotificationRow"]
        group_toggle = None
        target = None
        for row in rows:
            if not contains(row, title):
                continue
            children = list(row.iter("node"))
            if any(resource(n) == "expandableNotificationRow" for n in children[1:]):
                group_toggle = next((n for n in children if resource(n) == "expand_button"
                                     and n.get("content-desc") == "Expand"
                                     and any(resource(k) == "expand_button_number" for k in n.iter("node"))), None)
            elif contains(row, body):
                target = next(n for n in children if body in
                              (n.get("content-desc") or n.get("text") or "").splitlines())
        if group_toggle is not None:
            device.tap_node(group_toggle)
            time.sleep(0.5)
            continue
        if target is not None:
            device.tap_node(target)
            break
        time.sleep(0.3)
    else:
        raise RuntimeError("Android did not expose the requested child notification")

    for _ in range(15):
        click = last_click()
        if click != previous:
            if f"|{PACKAGE}|0|{tag}|" not in click:
                raise RuntimeError("Android clicked a different notification or its group summary")
            return
        time.sleep(0.2)
    raise RuntimeError("Android did not confirm the physical notification click")


def system_tap(device, cfg, cold):
    first, second, owner = cfg["firstId"], cfg["secondId"], cfg["recipientId"]
    target, other = ("second", "first") if cold else ("first", "second")
    check_chat_reads(cfg, set() if cold else {"second"})
    device.expect_ids(owner, {first, second} if cold else {first}, observed={first, second})
    device.run("shell", "input", "keyevent", "KEYCODE_HOME")

    def pid():
        result = subprocess.run([*device.prefix, "shell", "pidof", PACKAGE], capture_output=True, timeout=8)
        if result.returncode == 1 and not result.stdout.strip():
            return None
        result.check_returncode()
        return int(result.stdout.strip())

    previous_pid = pid()
    if previous_pid is None:
        raise RuntimeError("Expected a running test fixture before the tap scenario")
    if cold:
        for _ in range(20):
            device.run("shell", "am", "kill", PACKAGE)
            time.sleep(1)
            if pid() is None:
                break
        else:
            raise RuntimeError("Android did not stop the background process")
        device.expect_ids(owner, {first, second}, observed={first, second})

    tap_system_card(device, cfg[target + "Title"], cfg[target + "Marker"],
                    f"student:{owner}:{cfg[target + 'Id']}")
    device.find(cfg[target + "Marker"], wait=55)
    if any(cfg[other + "Marker"] in ((n.get("content-desc") or "") + (n.get("text") or ""))
           for n in device.nodes()):
        raise RuntimeError("The other conversation's content is visible")
    new_pid = pid()
    if new_pid is None or (new_pid != previous_pid) != cold:
        raise RuntimeError("Unexpected process lifecycle for system notification tap")
    device.expect_ids(owner, {first} if cold else set(), observed={first, second})
    check_chat_reads(cfg, {"second"} if cold else {"first", "second"})
    print("PASS correct DM history from system notification in a " +
          ("new Android process" if cold else "resumed Android process"), flush=True)
    print("PASS matching backend read cursors and notification read receipts", flush=True)


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
    parser.add_argument("action", choices=["prepare", "read", "materials", "pair", "removed", "replay", "cold-tap", "warm-tap"])
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
    elif opts.action in ("cold-tap", "warm-tap"):
        system_tap(device, cfg, cold=opts.action == "cold-tap")
    else:
        background(device, cfg, opts.action, opts.private)


if __name__ == "__main__":
    main()
