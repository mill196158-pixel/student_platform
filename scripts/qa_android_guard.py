"""Read-only, fail-closed preflight for *future* isolated Android QA tests.

This program never installs, uninstalls, clears, starts an emulator or runs tests.
A PASS is only a point-in-time preflight, not proof that a later Flutter rebuild
will use the inspected APK. See docs/design/QA_INTEGRATION_GUARD.md.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

PRODUCTION = 'com.mill453020.studentplatform'
QA_PREFIX = 'com.mill453020.studentplatform.qa.'
SERIAL = re.compile(r'emulator-[0-9]{4,5}\Z')
AVD = re.compile(r'Codex_QA_[A-Za-z0-9_]+\Z')
PACKAGE = re.compile(r'com\.mill453020\.studentplatform\.qa\.[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\Z')

class GuardError(Exception):
    pass

def command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GuardError('Required tool unavailable or timed out') from exc
    if result.returncode != 0:
        raise GuardError('Required read-only device or APK query failed')
    return result.stdout

def check(*, adb, aapt, apk, gradle, serial, avd, user, qa_package, runner=command):
    if not SERIAL.fullmatch(serial) or not AVD.fullmatch(avd):
        raise GuardError('A dedicated Codex_QA_ AVD and exact emulator serial are required')
    if not PACKAGE.fullmatch(qa_package) or qa_package == PRODUCTION:
        raise GuardError('A separate explicitly named QA package is required')
    if not user.isdecimal():
        raise GuardError('Expected Android user must be a numeric ID')
    for binary in (adb, aapt):
        if not Path(binary).is_absolute() or not Path(binary).is_file():
            raise GuardError('ADB and aapt must be existing absolute paths')
    if not apk.is_file() or apk.suffix.lower() != '.apk' or not gradle.is_file():
        raise GuardError('A concrete existing APK and Gradle file are required')
    source = gradle.read_text(encoding='utf-8')
    # Fail closed on non-literal, multiple, flavor-specific, or ambiguous values.
    if re.search(r'\bproductFlavors\b|\bapplicationIdSuffix\b|\bnamespaceSuffix\b', source):
        raise GuardError('Dynamic/flavor Gradle configuration is not supported')
    values = {}
    for key in ('namespace', 'applicationId'):
        # Strictly allow a single mention, not merely a single literal
        # assignment: a later setter, qualified assignment, suffix, comment,
        # or reference is ambiguous and must refuse. This intentionally
        # rejects harmless references as well.
        if len(re.findall(re.escape(key), source, flags=re.IGNORECASE)) != 1:
            raise GuardError(f'Gradle {key} must occur exactly once')
        matches = re.findall(r'^\s*' + key + r'\s*=\s*"([A-Za-z0-9_.]+)"\s*$', source, re.M)
        if len(matches) != 1 or matches[0] != qa_package:
            raise GuardError(f'Gradle {key} must be a unique literal QA package')
        values[key] = matches[0]
    badging = runner([aapt, 'dump', 'badging', str(apk)])
    ids = re.findall(r"^package: name='([^']+)'", badging, re.M)
    if len(ids) != 1 or ids[0] != qa_package:
        raise GuardError('APK package does not exactly match QA package')
    devices = runner([adb, 'devices'])
    matches = [line.split() for line in devices.splitlines() if line.strip() and not line.startswith('List of devices')]
    if sum(len(row) == 2 and row[0] == serial and row[1] == 'device' for row in matches) != 1:
        raise GuardError('Exact serial must be present once and online')
    actual_avd = runner([adb, '-s', serial, 'emu', 'avd', 'name']).splitlines()
    if [line.strip() for line in actual_avd if line.strip() and line.strip() != 'OK'] != [avd]:
        raise GuardError('Running AVD identity differs from the dedicated QA AVD')
    current = runner([adb, '-s', serial, 'shell', 'am', 'get-current-user']).strip()
    if current != user:
        raise GuardError('Android current user differs from the explicitly approved user')
    listed = runner([adb, '-s', serial, 'shell', 'pm', 'list', 'users'])
    users = re.findall(r'UserInfo\{([0-9]+):', listed)
    if ('Users:' not in listed or not users or len(users) != len(set(users)) or
            len(re.findall(r'UserInfo\{', listed)) != len(users) or current not in users):
        raise GuardError('Unable to establish all Android users/profiles')
    for profile in users:
        listing = runner([adb, '-s', serial, 'shell', 'pm', 'list', 'packages', '-u', '--user', profile])
        lines = listing.splitlines()
        if any(not re.fullmatch(r'package:[A-Za-z0-9_.]+', line.strip()) for line in lines if line.strip()):
            raise GuardError('Unexpected package list response')
        if not lines:
            raise GuardError('Empty package list is not trusted')
        if f'package:{PRODUCTION}' in [line.strip() for line in lines]:
            raise GuardError('Production package exists for an Android user/profile')
    return {'serial':serial, 'avd':avd, 'user':current, 'qa_package':qa_package, 'profiles':len(users)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('adb', 'aapt', 'apk', 'gradle', 'serial', 'avd', 'user', 'qa-package'):
        parser.add_argument('--' + name, required=True)
    # Required declaration only; this tool does not run Flutter.
    parser.add_argument('--no-uninstall', action='store_true', required=True)
    args = parser.parse_args()
    try:
        result = check(adb=args.adb, aapt=args.aapt, apk=Path(args.apk), gradle=Path(args.gradle),
                       serial=args.serial, avd=args.avd, user=args.user, qa_package=args.qa_package)
    except (GuardError, OSError, UnicodeError) as exc:
        print(f'REFUSED: {exc}', file=sys.stderr)
        return 1
    print('PASS (preflight only):', result)
    return 0

if __name__ == '__main__':
    sys.exit(main())
