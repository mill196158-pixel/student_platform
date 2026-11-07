"""Bind selected existing legacy drafts to the verified local session.

Windows only. The target application is disabled and stopped during writes, then its
original enabled state is restored. A verified DPAPI-encrypted backup of the complete original
preferences is created before an atomic on-device replacement. Nothing from
the preferences or the session is printed. The operation checks the package remains disabled and has no UID processes.
If the process appears or bytes differ unexpectedly, automatic rollback stops
to avoid overwriting concurrent app data and the encrypted backup is retained.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import contextlib
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from ctypes import wintypes
from pathlib import Path
from xml.sax.saxutils import escape

PACKAGE = 'com.mill453020.studentplatform'
PREFS = 'shared_prefs/FlutterSharedPreferences.xml'
SESSION_KEY = 'flutter.sb-gwdanmwluhrcfxbnplwd-auth-token'
MARKER_KEY = 'flutter.account_draft_legacy_owner_v1'
PROJECT = 'https://gwdanmwluhrcfxbnplwd.supabase.co'


class Blob(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]


def dpapi(data: bytes, protect: bool) -> bytes:
    if sys.platform != 'win32':
        raise RuntimeError('Windows DPAPI required')
    source = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    src, dest = Blob(len(data), source), Blob()
    crypt = ctypes.windll.crypt32
    if protect:
        ok = crypt.CryptProtectData(ctypes.byref(src), None, None, None, None, 1, ctypes.byref(dest))
    else:
        ok = crypt.CryptUnprotectData(ctypes.byref(src), None, None, None, None, 1, ctypes.byref(dest))
    if not ok:
        raise RuntimeError('DPAPI operation failed')
    try:
        return ctypes.string_at(dest.data, dest.size)
    finally:
        free = ctypes.windll.kernel32.LocalFree
        free.argtypes = [wintypes.HLOCAL]
        free.restype = wintypes.HLOCAL
        free(ctypes.cast(dest.data, wintypes.HLOCAL))


def prepare(xml: bytes, login: str, conversations: list[str]) -> bytes:
    if not re.fullmatch(r'[A-Za-z0-9._@-]{1,128}', login):
        raise ValueError('Invalid expected login')
    if not conversations or len(conversations) > 8 or len(set(conversations)) != len(conversations):
        raise ValueError('Select one to eight distinct conversations')
    if any(not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', c) for c in conversations):
        raise ValueError('Invalid conversation identifier')
    root = ET.fromstring(xml)
    if root.tag != 'map':
        raise ValueError('Unexpected preferences format')
    entries = {child.attrib.get('name'): child for child in root}
    if MARKER_KEY in entries:
        raise ValueError('An existing migration marker must be reviewed first')
    session_node = entries.get(SESSION_KEY)
    if session_node is None or session_node.tag != 'string' or not session_node.text:
        raise ValueError('Stored session is absent')
    session = json.loads(session_node.text)
    user = session.get('user')
    if not isinstance(user, dict):
        raise ValueError('Stored user is absent')
    owner = str(uuid.UUID(str(user.get('id', ''))))
    metadata = user.get('user_metadata') or {}
    app_metadata = user.get('app_metadata') or {}
    if not isinstance(metadata, dict) or not isinstance(app_metadata, dict):
        raise ValueError('Unexpected user metadata')
    allowed_logins = {str(metadata.get('login', '')), str(app_metadata.get('login', '')),
                      str(user.get('email', '')).removesuffix('@student.local')}
    if login not in allowed_logins:
        raise ValueError('Expected login does not match this stored session')
    token = session.get('access_token', '')
    pieces = token.split('.') if isinstance(token, str) else []
    if len(pieces) != 3:
        raise ValueError('Stored session token is malformed')
    claims = json.loads(base64.urlsafe_b64decode(pieces[1] + '=' * (-len(pieces[1]) % 4)))
    if claims.get('sub') != owner or claims.get('iss') != PROJECT + '/auth/v1':
        raise ValueError('Stored session identity or project does not match')
    uuid.UUID(str(claims.get('session_id', '')))
    drafts = []
    for key in ('flutter.global_draft_texts', 'flutter.global_draft_files'):
        node = entries.get(key)
        value = json.loads(node.text) if node is not None and node.text else {}
        if not isinstance(value, dict):
            raise ValueError('Legacy draft index is malformed')
        drafts.append(value)
    if any(not any(conversation in store and store[conversation] for store in drafts)
           for conversation in conversations):
        raise ValueError('A selected conversation has no saved legacy draft')
    marker = json.dumps({'project': PROJECT, 'owner': owner, 'conversations': conversations},
                        ensure_ascii=True, separators=(',', ':'))
    insertion = ('<string name="' + MARKER_KEY + '">' + escape(marker) + '</string>\n').encode('utf-8')
    if xml.count(b'</map>') != 1:
        raise ValueError('Unexpected preferences document')
    changed = xml.replace(b'</map>', insertion + b'</map>')
    if ET.fromstring(changed).find("string[@name='" + MARKER_KEY + "']") is None:
        raise ValueError('Prepared marker failed validation')
    return changed


def prepare_removal(xml: bytes, login: str, conversations: list[str]) -> bytes:
    """Remove only a marker matching the verified session and selection."""
    root = ET.fromstring(xml)
    nodes = [child for child in root if child.attrib.get('name') == MARKER_KEY]
    if len(nodes) != 1 or nodes[0].tag != 'string' or not nodes[0].text:
        raise ValueError('Expected marker is absent or ambiguous')
    marker = json.loads(nodes[0].text)
    pattern = rb'<string name="' + re.escape(MARKER_KEY.encode()) + rb'">[^<]*</string>'
    matches = list(re.finditer(pattern, xml))
    if len(matches) != 1:
        raise ValueError('Marker encoding is unexpected')
    match = matches[0]
    changed = xml[:match.start()] + xml[match.end():]
    # Reuse the full session, issuer, login and selection verification.
    expected_xml = prepare(changed, login, conversations)
    expected_node = ET.fromstring(expected_xml).find("string[@name='" + MARKER_KEY + "']")
    if expected_node is None or json.loads(expected_node.text or '') != marker:
        raise ValueError('Marker does not match the verified session and selection')
    return changed


def adb(serial: str, *args: str, payload: bytes | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(['adb', '-s', serial, *args], input=payload,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)



def package_enabled_state(serial: str) -> int:
    data = adb(serial, 'shell', 'dumpsys', 'package', PACKAGE).stdout.decode('utf-8', 'replace')
    matches = re.findall(r'^\s*User 0:.*?\benabled=(\d+)\b', data, re.MULTILINE)
    if len(matches) != 1 or int(matches[0]) not in (0, 1, 2, 3, 4):
        raise RuntimeError('Cannot confirm original package enabled state')
    return int(matches[0])


@contextlib.contextmanager
def suspended_package(serial: str):
    # Restore precisely the original state even when validation or writing fails.
    previous = package_enabled_state(serial)
    commands = {0: 'default-state', 1: 'enable', 2: 'disable',
                3: 'disable-user', 4: 'disable-until-used'}
    try:
        adb(serial, 'shell', 'pm', 'disable-user', '--user', '0', PACKAGE)
        if package_enabled_state(serial) != 3:
            raise RuntimeError('Package could not be disabled for the operation')
        adb(serial, 'shell', 'am', 'force-stop', '--user', '0', PACKAGE)
        yield
    finally:
        adb(serial, 'shell', 'pm', commands[previous], '--user', '0', PACKAGE)
        if package_enabled_state(serial) != previous:
            raise RuntimeError('Original package enabled state was not restored')

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--login', required=True)
    parser.add_argument('--conversation', action='append', required=True)
    parser.add_argument('--backup', required=True, type=Path,
                        help='New path for a DPAPI-encrypted full preferences backup')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true', help='Write the verified marker')
    mode.add_argument('--remove', action='store_true', help='Remove only the matching marker')
    mode.add_argument('--restore-from', type=Path, help='Restore an exact DPAPI backup after comparing current bytes')
    parser.add_argument('--expected-current-sha256', help='Required exact current preferences SHA-256 for restore')
    args = parser.parse_args()
    try:
        if sys.platform != 'win32':
            raise RuntimeError('Windows DPAPI required')
        def require_stopped() -> None:
            if (args.apply or args.remove or args.restore_from) and package_enabled_state(args.serial) != 3:
                raise RuntimeError('Package is no longer disabled')
            state = adb(args.serial, 'get-state')
            if state.stdout.strip() != b'device':
                raise RuntimeError('Selected device is not ready')
            android_user = adb(args.serial, 'shell', 'am', 'get-current-user').stdout.strip()
            if android_user != b'0':
                raise RuntimeError('Only the primary Android user is supported')
            package_info = adb(args.serial, 'shell', 'dumpsys', 'package', PACKAGE).stdout.decode('utf-8', 'replace')
            ids = set(re.findall(r'\bappId=(\d+)\b', package_info))
            if not ids:
                ids = {value for value in re.findall(r'\buserId=(\d+)\b', package_info)
                       if int(value) >= 10000}
            if len(ids) != 1:
                raise RuntimeError('Cannot confirm the application UID')
            uid = int(ids.pop())
            if uid < 10000:
                raise RuntimeError('Unexpected application UID')
            inventory = adb(args.serial, 'shell', 'pm', 'list', 'packages', '--uid', str(uid)).stdout.decode('utf-8', 'replace')
            lines = [line.strip() for line in inventory.splitlines() if line.strip()]
            if len(lines) != 1 or not re.fullmatch(
                    r'package:' + re.escape(PACKAGE) + r'(?:\s+uid:' + str(uid) + r')?', lines[0]):
                raise RuntimeError('Application UID is shared or package inventory is unverified')
            names = {str(uid), f'u{uid // 100000}_a{uid % 100000 - 10000}'}
            processes = adb(args.serial, 'shell', 'ps', '-A', '-o', 'UID,NAME').stdout.decode('utf-8', 'replace')
            process_lines = processes.splitlines()
            if len(process_lines) < 2 or process_lines[0].split() != ['UID', 'NAME']:
                raise RuntimeError('Cannot confirm the complete process list')
            for line in process_lines[1:]:
                fields = line.split(None, 1)
                if len(fields) != 2:
                    raise RuntimeError('Cannot confirm the complete process list')
                process_uid, name = fields
                if process_uid in names or name == PACKAGE or name.startswith(PACKAGE + ':'):
                    raise RuntimeError('An application UID process is running')
            backup_file = adb(args.serial, 'shell', '-T',
                f"run-as {PACKAGE} sh -c 'test ! -e {PREFS}.bak'", check=False)
            if backup_file.returncode != 0 or backup_file.stderr.strip():
                raise RuntimeError('Android preferences .bak exists or cannot be checked')

        with suspended_package(args.serial) if (args.apply or args.remove or args.restore_from) else contextlib.nullcontext():
            if args.restore_from and not re.fullmatch(r'[0-9a-f]{64}', args.expected_current_sha256 or ''):
                raise ValueError('Restore requires an exact lowercase current SHA-256')
            if args.expected_current_sha256 and not args.restore_from:
                raise ValueError('Expected current hash is only valid for restore')
            require_stopped()
            original = adb(args.serial, 'exec-out', 'run-as', PACKAGE, 'cat', PREFS).stdout
            if args.restore_from:
                if hashlib.sha256(original).hexdigest() != args.expected_current_sha256:
                    raise ValueError('Current preferences do not match the expected hash')
                changed = dpapi(args.restore_from.read_bytes(), False)
                # Backup must describe this exact owner and selected legacy chats.
                restored_root = ET.fromstring(changed)
                restored_markers = [node for node in restored_root if node.attrib.get('name') == MARKER_KEY]
                if restored_markers:
                    prepare_removal(changed, args.login, args.conversation)
                else:
                    prepare(changed, args.login, args.conversation)
            else:
                changed = (prepare_removal(original, args.login, args.conversation)
                           if args.remove else prepare(original, args.login, args.conversation))
            if not args.apply and not args.remove and not args.restore_from:
                print('Validation succeeded; no device changes made.')
                return 0
            encrypted = dpapi(original, True)
            if dpapi(encrypted, False) != original:
                raise RuntimeError('Backup verification failed')
            with open(args.backup, 'xb') as output:
                output.write(encrypted)
                output.flush()
                os.fsync(output.fileno())
            if dpapi(args.backup.read_bytes(), False) != original:
                raise RuntimeError('On-disk backup verification failed')
            require_stopped()
            def replace_preferences(value: bytes, expected: bytes) -> None:
                # Fixed commands only; XML goes through stdin and is never printed.
                expected_hash = hashlib.sha256(expected).hexdigest()
                cmd = ("test ! -e shared_prefs/.codex_draft_marker.tmp && "
                       "cat > shared_prefs/.codex_draft_marker.tmp && "
                       "chmod 600 shared_prefs/.codex_draft_marker.tmp && "
                       "sync -f shared_prefs/.codex_draft_marker.tmp && "
                       f"test ! -e {PREFS}.bak && "
                       f'test "$(sha256sum {PREFS} | cut -d " " -f 1)" = "{expected_hash}" && '
                       "mv shared_prefs/.codex_draft_marker.tmp " + PREFS + " && "
                       "sync -f shared_prefs")
                adb(args.serial, 'shell', '-T', f"run-as {PACKAGE} sh -c '{cmd}'", payload=value)

            try:
                replace_preferences(changed, original)
                require_stopped()
                observed = adb(args.serial, 'exec-out', 'run-as', PACKAGE, 'cat', PREFS).stdout
                if observed != changed:
                    raise RuntimeError('Post-write bytes differ')
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                # Never overwrite any unexpected bytes or a restarted app. Roll
                # back only an exact marker-only result while the app is stopped.
                rollback = 'manual inspection required'
                try:
                    require_stopped()
                    observed = adb(args.serial, 'exec-out', 'run-as', PACKAGE, 'cat', PREFS).stdout
                    if observed == original:
                        rollback = 'original preferences unchanged'
                    elif observed == changed:
                        replace_preferences(original, changed)
                        require_stopped()
                        verified = adb(args.serial, 'exec-out', 'run-as', PACKAGE, 'cat', PREFS).stdout
                        if verified == original:
                            rollback = 'original preferences restored and verified'
                except (OSError, subprocess.SubprocessError, RuntimeError):
                    pass
                raise RuntimeError(f'Marker write failed; {rollback}; encrypted backup retained') from error
        print('Marker change verified. App remains stopped; encrypted backup retained.')
        return 0
    except (ValueError, RuntimeError) as error:
        print(f'{error}; inspect device state and retain any encrypted backup.', file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError, ET.ParseError, json.JSONDecodeError):
        print('Validation or write failed; inspect device state and retain any encrypted backup.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
