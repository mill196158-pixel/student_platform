import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/deadline_projection_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('dirty marker survives abrupt process exit; uncommitted transaction rolls back', () async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('deadline-crash-');
    final databasePath = '${dir.path}/deadlines.db';
    var store = await DeadlineProjectionStore.open(databasePath: databasePath, factory: databaseFactoryFfi);
    expect(await store.saveConfirmed('project-a', 'user', 'month', 0, 'old', () => true), isTrue);
    await store.db.close();
    for (final phase in ['before', 'after']) {
      final child = await Process.run('flutter', ['test', '--no-pub', 'test/support/deadline_crash_fixture.dart'],
          environment: {'DEADLINE_DB_PATH': databasePath, 'DEADLINE_CRASH_PHASE': phase},
          includeParentEnvironment: true, runInShell: Platform.isWindows).timeout(const Duration(seconds: 90));
      expect(child.exitCode, isNot(0));
      expect('${child.stdout}${child.stderr}', contains('DEADLINE_${phase.toUpperCase()}_COMMIT'));
      store = await DeadlineProjectionStore.open(databasePath: databasePath, factory: databaseFactoryFfi);
      expect(await store.read('project-a', 'user', 'month'), phase == 'before' ? 'old' : isNull);
      await store.db.close();
    }
  }, timeout: const Timeout(Duration(seconds: 180)));
}
