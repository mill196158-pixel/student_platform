"""Drive the ordinary Flutter login and DM screens on an isolated Android AVD.

Install the ordinary_android_loopback_main.dart debug fixture on a fresh
Student_Ordinary_QA_Journey_ AVD. Supply its serial, two local account config
paths, the seeded DM manifest and the public CA from qa_local_android_gateway.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from uuid import UUID, uuid4

from local_e2e_api import request, rpc
from qa_android_background_push_materials import Device, PACKAGE


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def check_invalid_password(device):
    # The usual uiautomator dump waits for UI idle and may miss a SnackBar.
    # Use the SDK's native UIAutomator runner to watch the actual transient view.
    sdk = Path(shutil.which("adb")).resolve().parents[1]
    platform = sdk / "platforms/android-34"
    libs = [str(platform / name) for name in
            ("android.jar", "uiautomator.jar", "optional/android.test.base.jar")]
    compiler = Path(shutil.which("javac")).resolve()
    env = {**os.environ, "JAVA_HOME": str(compiler.parents[1])}
    source = Path(__file__).parent / "android_qa/OrdinaryLoginProbe.java"
    jar_name = "ordinary-login-probe.jar"
    d8 = sdk / "build-tools/36.0.0" / ("d8.bat" if os.name == "nt" else "d8")
    with tempfile.TemporaryDirectory() as output:
        dest = Path(output)
        subprocess.run([compiler, "-encoding", "UTF-8", "-source", "8", "-target", "8",
                        "-classpath", os.pathsep.join(libs), "-d", dest, source],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        subprocess.run([d8, *[v for lib in libs for v in ("--lib", lib)], "--output",
                        dest / jar_name, dest / "qa/ordinary/OrdinaryLoginProbe.class"],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        device.run("push", str(dest / jar_name), "/data/local/tmp/" + jar_name)
    result = device.run("shell", "uiautomator", "runtest", jar_name, "-c",
                        "qa.ordinary.OrdinaryLoginProbe#testWrongPassword")
    if not re.search(rb"OK\s*\(1 test\)", result):
        raise RuntimeError("The on-device login error assertion failed")


def enter(device, index, value, *, password=False):
    # Avoid putting a test password in the host adb process arguments.
    if not re.fullmatch(r"[A-Za-z0-9_.@ -]+", value):
        raise ValueError("Use an ASCII QA credential without shell punctuation")

    def field():
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                fields = [n for n in device.nodes() if n.get("class") == "android.widget.EditText"]
                if index < len(fields):
                    return fields[index]
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                pass
            time.sleep(.25)
        raise RuntimeError("Expected an editable field in the ordinary app")

    previous = field()
    previous_length = len(previous.get("text", ""))
    device.tap_node(previous)
    time.sleep(.7)
    if password and previous_length:
        device.run("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        device.run("shell", "input", "keyevent", *(["KEYCODE_DEL"] * previous_length))
    device.run("shell", "-T", input=("input text '" + value.replace(" ", "%s") + "'\n").encode())
    # Android IME can lose the first keystroke before focus is ready.
    displayed = field().get("text", "")
    entered = len(displayed) == len(value) if password else displayed == value
    if not entered:
        raise RuntimeError("Test keyboard did not enter the requested value")


def profile(device):
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        try:
            nodes = device.nodes()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            time.sleep(.3)
            continue
        for node in nodes:
            label = (node.get("content-desc") or node.get("text") or "").splitlines()
            if "Не сейчас" in label:
                device.tap_node(node)
                break
            if "Профиль" in label:
                device.tap_node(node)
                return
        time.sleep(.3)
    raise RuntimeError("Profile was not available on the ordinary home screen")


def open_chat(device, manifest, expected):
    profile(device)
    device.tap("Сообщения")
    device.tap(manifest["peer_name"])
    device.find(expected)


def main(options):
    first, peer, manifest = map(read_json, (options.first, options.peer, options.chat))
    for cfg in (first, peer):
        if cfg["port"] != 55321 or not cfg["login"].startswith("e2e_"):
            raise ValueError("Dedicated local QA students required")
    if first["recipientId"] == peer["recipientId"]:
        raise ValueError("Use two distinct students")
    chat_id = str(UUID(manifest["chat_id"]))
    device = Device(options.serial, avd_prefix="Student_Ordinary_QA_Journey_")
    if device.run("shell", "cmd", "connectivity", "airplane-mode").strip() != b"enabled":
        raise RuntimeError("Put the dedicated AVD in airplane mode first")
    if b"Active default network: none" not in device.run("shell", "dumpsys", "connectivity"):
        raise RuntimeError("The local AVD has a default network")
    cert = options.ca.read_bytes()
    if b"-----BEGIN CERTIFICATE-----" not in cert or b"PRIVATE KEY" in cert:
        raise ValueError("Supply only the public local CA")

    code, grant = request("/auth/v1/token?grant_type=password",
                          {"email": peer["email"], "password": peer["password"]})
    if code != 200 or grant["user"]["id"] != peer["recipientId"]:
        raise RuntimeError("The local peer could not authenticate")
    token = grant["access_token"]

    def history():
        code, page = rpc("get_chat_messages_page", token, p_chat_id=chat_id)
        if code != 200:
            raise RuntimeError("Local DM history failed")
        return page

    if not any(m["id"] == manifest["message_id"] and m["text"] == manifest["body"] for m in history()):
        raise RuntimeError("The authenticated peer cannot see the seeded DM")

    def reply(text):
        code, _ = rpc("send_message_in_chat_with_files", token, p_chat_id=chat_id,
                      p_text=text, p_file_ids=[])
        if code != 200:
            raise RuntimeError("The peer could not send its message")

    device.run("reverse", "tcp:55443", "tcp:55443")
    device.run("shell", "run-as", PACKAGE, "mkdir", "-p", "files")
    device.write_private("ordinary_test_ca.pem", cert)
    device.start()
    device.tap("Войти", wait=55)
    device.find("С возвращением")
    enter(device, 0, first["login"])
    enter(device, 1, "wrong-" + uuid4().hex[:14], password=True)
    device.run("shell", "input", "keyevent", "KEYCODE_BACK")
    check_invalid_password(device)
    print("PASS incorrect password returned the localized error and retained the login form", flush=True)
    enter(device, 1, first["password"], password=True)
    device.run("shell", "input", "keyevent", "KEYCODE_BACK")
    device.tap("Войти")
    open_chat(device, manifest, manifest["body"])
    print("PASS Android password login, personal home, profile, message list and seeded DM", flush=True)

    marker = uuid4().hex[:12]
    outgoing, incoming, stopped = (f"QA {label} {marker}" for label in ("out", "in", "stopped"))
    enter(device, 0, outgoing)
    device.tap("Отправить")
    device.find(outgoing)
    if sum(m["text"] == outgoing for m in history()) != 1:
        raise RuntimeError("The peer did not receive exactly one outgoing message")
    reply(incoming)
    device.find(incoming, wait=35)
    print("PASS second account read the single outbound and replied into the open Android chat", flush=True)

    old = device.run("shell", "pidof", PACKAGE).strip()
    device.run("shell", "am", "force-stop", PACKAGE)
    dead = subprocess.run([*device.prefix, "shell", "pidof", PACKAGE], capture_output=True, timeout=5)
    if not old or dead.returncode != 1 or dead.stdout.strip():
        raise RuntimeError("Android did not stop the test process")
    reply(stopped)
    device.start()
    open_chat(device, manifest, stopped)
    new = device.run("shell", "pidof", PACKAGE).strip()
    if not new or new == old:
        raise RuntimeError("Android did not restart the test process")
    for body in (outgoing, incoming, stopped):
        device.find(body, wait=25)
    final = history()
    if any(sum(m["text"] == value for m in final) != 1 for value in (outgoing, incoming, stopped)):
        raise RuntimeError("Conversation history contains a missing or duplicated message")
    print("PASS new Android process restored the session, prior exchange and message sent while stopped", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    for argument in ("first", "peer", "chat", "ca"):
        parser.add_argument(argument, type=Path)
    main(parser.parse_args())
