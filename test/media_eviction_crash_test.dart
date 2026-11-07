import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('synthetic process exit after rename leaves recoverable protected bytes',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('student-media-crash-');
    try {
      final child = await Process.run(
              'flutter',
              [
                'test',
                '--no-pub',
                '--dart-define=MEDIA_CACHE_EVICTION_QA=true',
                'test/support/media_eviction_crash_fixture.dart'
              ],
              environment: {'SYNTHETIC_MEDIA_CRASH_ROOT': root.path},
              includeParentEnvironment: true,
              runInShell: Platform.isWindows)
          .timeout(const Duration(seconds: 90));
      expect(child.exitCode, isNot(0));
      expect(
          '${child.stdout}${child.stderr}', contains('SYNTHETIC_MEDIA_STAGED'));
      final db = await databaseFactoryFfi.openDatabase('${root.path}/test.db');
      final store = MediaCacheProtection(
          db: db,
          root: root,
          project: 'project',
          databaseToken: 'new-guard',
          currentOwner: () => 'owner',
          currentSessionId: () => 'sid');
      final original = File(
          '${root.path}/authorized_chat_files/owner/${store.digest('owner', 'key')}');
      expect(await original.exists(), isFalse);
      expect(await store.recoverInterruptedEvictions('owner', () => true), 0);
      expect(
          await store.recoverInterruptedEvictions('owner', () => true,
              mayRestore: (token) => token == 'crashed-guard'),
          1);
      expect(await original.readAsBytes(), [11, 22, 33]);
      expect((await db.query('media_cache_objects')).single['pinned'], 1);
      await db.close();
    } finally {
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path)
        await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
