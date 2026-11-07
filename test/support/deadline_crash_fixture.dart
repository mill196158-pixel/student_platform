import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/deadline_projection_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('synthetic crash at dirty marker', () async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final store = await DeadlineProjectionStore.open(databasePath: Platform.environment['DEADLINE_DB_PATH']!, factory: databaseFactoryFfi);
    if (Platform.environment['DEADLINE_CRASH_PHASE'] == 'before') {
      await store.db.transaction((tx) async {
        await tx.rawUpdate('UPDATE owner_state SET revision=revision+1, dirty=1 WHERE project=? AND uid=?', ['project-a', 'user']);
        stdout.writeln('DEADLINE_BEFORE_COMMIT'); await stdout.flush(); exit(71);
      });
    } else {
      await store.markDirty('project-a', 'user');
      stdout.writeln('DEADLINE_AFTER_COMMIT'); await stdout.flush(); exit(72);
    }
  });
}
