import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/deadline_projection_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  sqfliteFfiInit();
  test('restart preserves clean snapshot and fences durable dirty snapshot', () async {
    final dir = await Directory.systemTemp.createTemp('deadline_projection_');
    final file = '${dir.path}/deadlines.sqlite';
    var store = await DeadlineProjectionStore.open(databasePath: file, factory: databaseFactoryFfi);
    expect(await store.saveConfirmed('project-a', 'user', 'month', 0, 'old', () => true), isTrue);
    await store.db.close();
    store = await DeadlineProjectionStore.open(databasePath: file, factory: databaseFactoryFfi);
    expect(await store.read('project-a', 'user', 'month'), 'old');
    final staleRevision = await store.revision('project-a', 'user');
    await store.markDirty('project-a', 'user');
    await store.db.close();
    store = await DeadlineProjectionStore.open(databasePath: file, factory: databaseFactoryFfi);
    expect(await store.read('project-a', 'user', 'month'), isNull);
    expect(await store.saveConfirmed('project-a', 'user', 'month', staleRevision, 'stale', () => true), isFalse);
    final currentRevision = await store.revision('project-a', 'user');
    expect(await store.saveConfirmed('project-a', 'user', 'month', currentRevision, 'fresh', () => true), isTrue);
    expect(await store.read('project-a', 'user', 'month'), 'fresh');
    expect(await store.read('project-b', 'user', 'month'), isNull);
    expect(await store.read('project-a', 'other', 'month'), isNull);
    await store.db.close();
  });
}
