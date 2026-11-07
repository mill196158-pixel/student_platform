import base64
import json
import unittest
import tempfile
import subprocess
import hashlib
import contextlib
from pathlib import Path
from unittest.mock import patch
import xml.etree.ElementTree as ET

import authorize_legacy_draft_marker as module
from authorize_legacy_draft_marker import MARKER_KEY, PROJECT, SESSION_KEY, prepare, prepare_removal


def encoded(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')


def sample():
    user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    token = f"{encoded({'alg': 'none'})}.{encoded({'iss': PROJECT + '/auth/v1', 'sub': user_id, 'session_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'})}.sig"
    session = {'user': {'id': user_id, 'user_metadata': {'login': 'test-login'}},
               'access_token': token}
    root = ET.Element('map')
    ET.SubElement(root, 'string', name=SESSION_KEY).text = json.dumps(session)
    ET.SubElement(root, 'string', name='flutter.global_draft_texts').text = json.dumps({'chat-1': 'draft'})
    ET.SubElement(root, 'string', name='flutter.global_draft_files').text = json.dumps({'chat-2': [{'path': '__FG__'}]})
    ET.SubElement(root, 'boolean', name='flutter.unrelated', value='true')
    return ET.tostring(root, encoding='utf-8')


class MarkerPreparationTest(unittest.TestCase):
    def test_prepares_only_selected_existing_conversations_and_preserves_other_xml(self):
        original = sample()
        result = prepare(original, 'test-login', ['chat-1', 'chat-2'])
        root = ET.fromstring(result)
        marker = json.loads(root.find(f"string[@name='{MARKER_KEY}']").text)
        self.assertEqual(marker['conversations'], ['chat-1', 'chat-2'])
        self.assertEqual(marker['owner'], 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        self.assertIn(b'<boolean name="flutter.unrelated" value="true"', result)
        marker_start = result.index(b'<string name="' + MARKER_KEY.encode() + b'">')
        self.assertEqual(result[:marker_start] + b'</map>', original)

    def test_rejects_wrong_owner_missing_conversation_and_existing_marker(self):
        original = sample()
        with self.assertRaises(ValueError):
            prepare(original, 'wrong-login', ['chat-1'])
        with self.assertRaises(ValueError):
            prepare(original, 'test-login', ['absent'])
        changed = prepare(original, 'test-login', ['chat-1'])
        with self.assertRaises(ValueError):
            prepare(changed, 'test-login', ['chat-2'])

    def test_removes_only_verified_marker_preserving_later_unrelated_changes(self):
        changed = prepare(sample(), 'test-login', ['chat-1'])
        later = changed.replace(b'</map>', b'<int name="flutter.new" value="3" /></map>')
        restored = prepare_removal(later, 'test-login', ['chat-1'])
        root = ET.fromstring(restored)
        self.assertIsNone(root.find(f"string[@name='{MARKER_KEY}']"))
        self.assertIsNotNone(root.find("int[@name='flutter.new']"))
        with self.assertRaises(ValueError):
            prepare_removal(later, 'wrong-login', ['chat-1'])
        with self.assertRaises(ValueError):
            prepare_removal(later, 'test-login', ['chat-2'])

    def test_failed_postrename_sync_restores_exact_original_when_app_stopped(self):
        initial = sample()
        device = {'xml': initial, 'writes': 0}

        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',):
                return subprocess.CompletedProcess(args, 0, b'device\n', b'')
            if args == ('shell', 'am', 'get-current-user'):
                return subprocess.CompletedProcess(args, 0, b'0\n', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'):
                return subprocess.CompletedProcess(args, 0, b'appId=10123\n', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:2] == ('shell', 'ps'):
                return subprocess.CompletedProcess(args, 0, b'UID NAME\nroot init\n', b'')
            if args[:2] == ('shell', '-T') and payload is None:
                return subprocess.CompletedProcess(args, 0, b'', b'')
            if args[0] == 'exec-out':
                return subprocess.CompletedProcess(args, 0, device['xml'], b'')
            if args[:2] == ('shell', '-T'):
                device['xml'] = payload
                device['writes'] += 1
                if device['writes'] == 1:
                    raise subprocess.CalledProcessError(1, 'synthetic-sync')
                return subprocess.CompletedProcess(args, 0, b'', b'')
            raise AssertionError('Unexpected synthetic adb call')

        def fake_dpapi(data, protect):
            return b'encrypted:' + data if protect else data.removeprefix(b'encrypted:')

        with tempfile.TemporaryDirectory(prefix='marker-test-') as directory:
            backup = Path(directory) / 'backup.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup), '--apply']
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module, 'dpapi', side_effect=fake_dpapi), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 1)
            self.assertEqual(device['xml'], initial)
            self.assertEqual(backup.read_bytes(), b'encrypted:' + initial)

    def test_app_restart_during_write_does_not_overwrite_new_device_state(self):
        initial = sample()
        device = {'xml': initial, 'checks': 0, 'writes': 0}

        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',):
                return subprocess.CompletedProcess(args, 0, b'device\n', b'')
            if args == ('shell', 'am', 'get-current-user'):
                return subprocess.CompletedProcess(args, 0, b'0\n', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'):
                return subprocess.CompletedProcess(args, 0, b'userId=10123\n', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:2] == ('shell', 'ps'):
                device['checks'] += 1
                processes = b'UID NAME\nu0_a123 com.mill453020.studentplatform:worker\n' if device['checks'] >= 3 else b'UID NAME\nroot init\n'
                return subprocess.CompletedProcess(args, 0, processes, b'')
            if args[:2] == ('shell', '-T') and payload is None:
                return subprocess.CompletedProcess(args, 0, b'', b'')
            if args[0] == 'exec-out':
                return subprocess.CompletedProcess(args, 0, device['xml'], b'')
            if args[:2] == ('shell', '-T'):
                device['xml'] = payload
                device['writes'] += 1
                return subprocess.CompletedProcess(args, 0, b'', b'')
            raise AssertionError('Unexpected synthetic adb call')

        def fake_dpapi(data, protect):
            return b'encrypted:' + data if protect else data.removeprefix(b'encrypted:')

        with tempfile.TemporaryDirectory(prefix='marker-test-') as directory:
            backup = Path(directory) / 'backup.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup), '--apply']
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module, 'dpapi', side_effect=fake_dpapi), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 1)
            self.assertEqual(device['writes'], 1)
            self.assertNotEqual(device['xml'], initial)
            self.assertEqual(backup.read_bytes(), b'encrypted:' + initial)

    def test_compare_before_replace_preserves_unexpected_new_bytes(self):
        initial = sample()
        modified = initial.replace(b'</map>', b'<int name="flutter.new" value="3" /></map>')
        device = {'xml': initial, 'checks': 0, 'writes': 0}

        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',):
                return subprocess.CompletedProcess(args, 0, b'device\n', b'')
            if args == ('shell', 'am', 'get-current-user'):
                return subprocess.CompletedProcess(args, 0, b'0\n', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'):
                return subprocess.CompletedProcess(args, 0, b'userId=10123\n', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:2] == ('shell', 'ps'):
                device['checks'] += 1
                if device['checks'] == 2:
                    device['xml'] = modified
                return subprocess.CompletedProcess(args, 0, b'UID NAME\nroot init\n', b'')
            if args[:2] == ('shell', '-T') and payload is None:
                return subprocess.CompletedProcess(args, 0, b'', b'')
            if args[0] == 'exec-out':
                return subprocess.CompletedProcess(args, 0, device['xml'], b'')
            if args[:2] == ('shell', '-T'):
                device['writes'] += 1
                if hashlib.sha256(device['xml']).hexdigest() not in args[2]:
                    raise subprocess.CalledProcessError(1, 'synthetic-compare')
                device['xml'] = payload
                return subprocess.CompletedProcess(args, 0, b'', b'')
            raise AssertionError('Unexpected synthetic adb call')

        def fake_dpapi(data, protect):
            return b'encrypted:' + data if protect else data.removeprefix(b'encrypted:')

        with tempfile.TemporaryDirectory(prefix='marker-test-') as directory:
            backup = Path(directory) / 'backup.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup), '--apply']
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module, 'dpapi', side_effect=fake_dpapi), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 1)
            self.assertEqual(device['xml'], modified)
            self.assertEqual(backup.read_bytes(), b'encrypted:' + initial)

    def test_suspension_restores_original_state_even_on_failure(self):
        for initial in (0, 1, 2, 3, 4):
            state = {'value': initial, 'commands': []}
            reverse = {'default-state': 0, 'enable': 1, 'disable': 2,
                       'disable-user': 3, 'disable-until-used': 4}
            def fake_adb(serial, *args, **kwargs):
                if args[:3] == ('shell', 'dumpsys', 'package'):
                    return subprocess.CompletedProcess(args, 0,
                        f'User 0: ceDataInode=1 enabled={state["value"]} stopped=true'.encode(), b'')
                if args[:2] == ('shell', 'pm'):
                    state['commands'].append(args[2])
                    state['value'] = reverse[args[2]]
                return subprocess.CompletedProcess(args, 0, b'', b'')
            with patch.object(module, 'adb', side_effect=fake_adb):
                with self.assertRaisesRegex(RuntimeError, 'synthetic'):
                    with module.suspended_package('synthetic'):
                        self.assertEqual(state['value'], 3)
                        raise RuntimeError('synthetic')
            self.assertEqual(state['value'], initial)
            self.assertEqual(state['commands'][0], 'disable-user')

    def test_restore_verified_exact_backup_and_preserves_replaced_bytes(self):
        original = sample()
        changed = prepare(original, 'test-login', ['chat-1'])
        device = {'xml': changed}
        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',): return subprocess.CompletedProcess(args, 0, b'device', b'')
            if args == ('shell', 'am', 'get-current-user'): return subprocess.CompletedProcess(args, 0, b'0', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'): return subprocess.CompletedProcess(args, 0, b'appId=10123', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'): return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:2] == ('shell', 'ps'): return subprocess.CompletedProcess(args, 0, b'UID NAME\nroot init', b'')
            if args[:2] == ('shell', '-T') and payload is None: return subprocess.CompletedProcess(args, 0, b'', b'')
            if args[0] == 'exec-out': return subprocess.CompletedProcess(args, 0, device['xml'], b'')
            if args[:2] == ('shell', '-T'):
                if hashlib.sha256(device['xml']).hexdigest() not in args[2]:
                    raise subprocess.CalledProcessError(1, 'synthetic-compare')
                device['xml'] = payload
                return subprocess.CompletedProcess(args, 0, b'', b'')
            raise AssertionError('Unexpected synthetic adb call')
        def fake_dpapi(data, protect):
            return b'encrypted:' + data if protect else data.removeprefix(b'encrypted:')
        with tempfile.TemporaryDirectory(prefix='marker-restore-') as directory:
            backup = Path(directory) / 'new.bin'
            old = Path(directory) / 'old.bin'
            old.write_bytes(b'encrypted:' + original)
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup),
                    '--restore-from', str(old), '--expected-current-sha256',
                    hashlib.sha256(changed).hexdigest()]
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module, 'dpapi', side_effect=fake_dpapi), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 0)
            self.assertEqual(device['xml'], original)
            self.assertEqual(backup.read_bytes(), b'encrypted:' + changed)
            marker_backup = Path(directory) / 'marker.bin'
            marker_backup.write_bytes(b'encrypted:' + changed)
            new_backup = Path(directory) / 'before-marker-restore.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(new_backup),
                    '--restore-from', str(marker_backup), '--expected-current-sha256',
                    hashlib.sha256(original).hexdigest()]
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module, 'dpapi', side_effect=fake_dpapi), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 0)
            self.assertEqual(device['xml'], changed)
            self.assertEqual(new_backup.read_bytes(), b'encrypted:' + original)

    def test_restore_rejects_unexpected_current_hash_before_write(self):
        initial = sample()
        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',): return subprocess.CompletedProcess(args, 0, b'device', b'')
            if args == ('shell', 'am', 'get-current-user'): return subprocess.CompletedProcess(args, 0, b'0', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'): return subprocess.CompletedProcess(args, 0, b'appId=10123', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'): return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:2] == ('shell', 'ps'): return subprocess.CompletedProcess(args, 0, b'UID NAME\nroot init', b'')
            if args[:2] == ('shell', '-T') and payload is None: return subprocess.CompletedProcess(args, 0, b'', b'')
            if args[0] == 'exec-out': return subprocess.CompletedProcess(args, 0, initial, b'')
            raise AssertionError('Restore must not write on hash mismatch')
        with tempfile.TemporaryDirectory(prefix='marker-restore-') as directory:
            backup = Path(directory) / 'backup.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup),
                    '--restore-from', str(Path(directory) / 'old.bin'),
                    '--expected-current-sha256', '0' * 64]
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 1)
            self.assertFalse(backup.exists())

    def test_shared_uid_package_blocks_any_preferences_access(self):
        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',): return subprocess.CompletedProcess(args, 0, b'device', b'')
            if args == ('shell', 'am', 'get-current-user'): return subprocess.CompletedProcess(args, 0, b'0', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'): return subprocess.CompletedProcess(args, 0, b'appId=10123', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0,
                    ('package:' + module.PACKAGE + ' uid:10123\npackage:other.app uid:10123').encode(), b'')
            raise AssertionError('Must reject before reading or writing prefs')
        with tempfile.TemporaryDirectory(prefix='marker-shared-uid-') as directory:
            backup = Path(directory) / 'backup.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup), '--apply']
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 1)
            self.assertFalse(backup.exists())

    def test_existing_android_atomicfile_backup_blocks_write(self):
        def fake_adb(serial, *args, payload=None, check=True):
            if args == ('get-state',):
                return subprocess.CompletedProcess(args, 0, b'device\n', b'')
            if args == ('shell', 'am', 'get-current-user'):
                return subprocess.CompletedProcess(args, 0, b'0\n', b'')
            if args[:3] == ('shell', 'dumpsys', 'package'):
                return subprocess.CompletedProcess(args, 0, b'userId=10123\n', b'')
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return subprocess.CompletedProcess(args, 0, ('package:' + module.PACKAGE + ' uid:10123').encode(), b'')
            if args[:2] == ('shell', 'ps'):
                return subprocess.CompletedProcess(args, 0, b'UID NAME\nroot init\n', b'')
            if args[:2] == ('shell', '-T') and payload is None:
                return subprocess.CompletedProcess(args, 1, b'', b'')
            raise AssertionError('Device write must not be attempted')

        with tempfile.TemporaryDirectory(prefix='marker-test-') as directory:
            backup = Path(directory) / 'backup.bin'
            args = ['script', '--serial', 'synthetic', '--login', 'test-login',
                    '--conversation', 'chat-1', '--backup', str(backup), '--apply']
            with patch.object(module, 'suspended_package', return_value=contextlib.nullcontext()), \
                 patch.object(module, 'package_enabled_state', return_value=3), \
                 patch.object(module, 'adb', side_effect=fake_adb), \
                 patch.object(module.sys, 'argv', args), \
                 patch.object(module.sys, 'platform', 'win32'):
                self.assertEqual(module.main(), 1)
            self.assertFalse(backup.exists())


if __name__ == '__main__':
    unittest.main()
