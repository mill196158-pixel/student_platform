import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/draft_recovery_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a committed journal survives abrupt synthetic process exit', () async {
    if (Platform.isWindows) open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('draft-journal-crash-');
    final path = '${directory.path}/recovery.db';
    try {
      final child = await Process.run('flutter',
          ['test', '--no-pub', 'test/support/draft_journal_crash_fixture.dart'],
          environment: {'DRAFT_JOURNAL_TEST_PATH': path},
          includeParentEnvironment: true, runInShell: Platform.isWindows)
          .timeout(const Duration(seconds: 90));
      expect(child.exitCode, isNot(0));
      expect('${child.stdout}${child.stderr}', contains('DRAFT_JOURNAL_COMMITTED'));
      final db = await databaseFactoryFfi.openDatabase(path);
      final journal = DraftRecoveryJournal(open: () async => db);
      expect(await journal.pending(project: 'test-project', owner: 'owner-b',
          conversation: 'chat', permitted: () => true), isEmpty);
      final restored = await journal.pending(project: 'test-project', owner: 'owner-a',
          conversation: 'chat', permitted: () => true);
      expect(restored.single['draft'], containsPair('text', 'survives synthetic crash'));
      await db.close();
    } finally {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final file = File('$path$suffix');
        if (await file.exists()) await file.delete();
      }
      if (await directory.exists()) await directory.delete();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
