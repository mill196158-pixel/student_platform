import importlib.util
import tempfile
import subprocess
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('guard', Path(__file__).parents[1] / 'scripts' / 'qa_android_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.adb = str(self.root / 'adb.exe'); Path(self.adb).touch()
        self.aapt = str(self.root / 'aapt.exe'); Path(self.aapt).touch()
        self.apk = self.root / 'qa.apk'; self.apk.touch()
        self.gradle = self.root / 'build.gradle.kts'
        self.qa = 'com.mill453020.studentplatform.qa.isolated'
        self.gradle.write_text(f'namespace = "{self.qa}"\napplicationId = "{self.qa}"\n', encoding='utf-8')
        self.responses = {
            'aapt': f"package: name='{self.qa}' versionCode='1'\n",
            'devices': 'List of devices attached\nemulator-5562\tdevice\n',
            'avd': 'Codex_QA_isolated\nOK\n',
            'current': '10\n',
            'users': 'Users:\n UserInfo{0:Owner:13} running\n UserInfo{10:QA:10} running\n',
            'packages0': 'package:android\n',
            'packages10': 'package:android\npackage:' + self.qa + '\n',
        }
        self.calls = []
    def tearDown(self): self.tmp.cleanup()
    def runner(self, cmd):
        self.calls.append(cmd)
        if cmd[0] == self.aapt: return self.responses['aapt']
        if cmd[1:] == ['devices']: return self.responses['devices']
        if cmd[3:] == ['emu', 'avd', 'name']: return self.responses['avd']
        if cmd[3:] == ['shell', 'am', 'get-current-user']: return self.responses['current']
        if cmd[3:] == ['shell', 'pm', 'list', 'users']: return self.responses['users']
        if cmd[3:8] == ['shell', 'pm', 'list', 'packages', '-u']:
            return self.responses['packages' + cmd[-1]]
        raise AssertionError(f'unexpected command: {cmd}')
    def run_guard(self, **kwargs):
        values = dict(adb=self.adb, aapt=self.aapt, apk=self.apk, gradle=self.gradle,
            serial='emulator-5562', avd='Codex_QA_isolated', user='10', qa_package=self.qa, runner=self.runner)
        values.update(kwargs)
        return guard.check(**values)
    def test_valid_is_read_only(self):
        self.assertEqual(self.run_guard()['user'], '10')
        self.assertTrue(all('uninstall' not in call and 'install' not in call and 'clear' not in call for call in self.calls))
    def test_refuses_production_or_malformed_device(self):
        for kwargs in [dict(avd='Pixel_9a'), dict(serial='device123'), dict(qa_package=guard.PRODUCTION), dict(user='all')]:
            with self.subTest(kwargs=kwargs), self.assertRaises(guard.GuardError): self.run_guard(**kwargs)
    def test_production_any_profile_including_uninstalled_is_refused(self):
        self.responses['packages0'] += 'package:' + guard.PRODUCTION + '\n'
        with self.assertRaises(guard.GuardError): self.run_guard()
        self.assertTrue(any('-u' in c for c in self.calls))
    def test_mismatch_user_avd_or_device_is_refused(self):
        for field, value in [('current','0'), ('avd','Pixel_9a\nOK\n'), ('devices','List of devices attached\nemulator-5562\toffline\n'), ('users','corrupt')]:
            old=self.responses[field]; self.responses[field]=value
            with self.subTest(field=field), self.assertRaises(guard.GuardError): self.run_guard()
            self.responses[field]=old
    def test_wrong_apk_or_gradle_or_flavor_is_refused(self):
        self.responses['aapt'] = f"package: name='{guard.PRODUCTION}'\n"
        with self.assertRaises(guard.GuardError): self.run_guard()
        self.responses['aapt'] = f"package: name='{self.qa}'\n"
        self.gradle.write_text(f'namespace = "{self.qa}"\napplicationId = "{guard.PRODUCTION}"\n', encoding='utf-8')
        with self.assertRaises(guard.GuardError): self.run_guard()
        self.gradle.write_text(f'namespace = "{self.qa}"\napplicationId = "{self.qa}"\nproductFlavors {{}}\n', encoding='utf-8')
        with self.assertRaises(guard.GuardError): self.run_guard()
    def test_rejects_dynamic_or_qualified_override_after_literal(self):
        base = f'namespace = "{self.qa}"\napplicationId = "{self.qa}"\n'
        extras = [
            'applicationId = System.getenv("PACKAGE")',
            'defaultConfig.applicationId = dynamicId',
            'applicationId.set(provider)',
            'namespace = System.getenv("NAMESPACE")',
            'android.namespace = mutableName',
            'namespace.set(provider)',
            '// applicationId may be overridden elsewhere',
            'APPLICATIONID = "another.package"',
        ]
        for extra in extras:
            self.gradle.write_text(base + extra + '\n', encoding='utf-8')
            with self.subTest(extra=extra), self.assertRaises(guard.GuardError):
                self.run_guard()
            self.assertEqual(self.calls, [], 'refusal must precede device and APK queries')
    def test_cli_refuses_without_explicit_no_uninstall(self):
        script = Path(__file__).parents[1] / 'scripts' / 'qa_android_guard.py'
        result = subprocess.run([sys.executable, str(script), '--adb', self.adb, '--aapt', self.aapt,
            '--apk', str(self.apk), '--gradle', str(self.gradle), '--serial', 'emulator-5562',
            '--avd', 'Codex_QA_isolated', '--user', '10', '--qa-package', self.qa],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--no-uninstall', result.stderr)
    def test_missing_or_untrusted_response_fails(self):
        self.responses['packages10']='Error: device unavailable\n'
        with self.assertRaises(guard.GuardError): self.run_guard()
        with self.assertRaises(guard.GuardError): self.run_guard(aapt='missing.exe')

if __name__ == '__main__': unittest.main()
