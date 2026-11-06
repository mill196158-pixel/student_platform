import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('new history database supports incremental vacuum without full migration', () async {
    final dir = await Directory.systemTemp.createTemp('history-vacuum-');
    final db = await openProjectChatServerDatabase('${dir.path}/cache.db',
        factory: databaseFactoryFfi);
    addTearDown(() async {
      await closeProjectChatServerDatabase(db);
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await dir.delete(recursive: true);
      }
    });
    final mode = await db.rawQuery('PRAGMA auto_vacuum');
    expect(mode.single.values.single, 2);
  });

  test('existing history database is not reconfigured or vacuumed', () async {
    final dir = await Directory.systemTemp.createTemp('history-vacuum-existing-');
    final path = '${dir.path}/cache.db';
    var old = await databaseFactoryFfi.openDatabase(path);
    await old.execute('CREATE TABLE chat_server_snapshot (project TEXT NOT NULL, uid TEXT NOT NULL, '
        'sid TEXT NOT NULL, chat TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(project,uid,sid,chat))');
    await old.execute('CREATE TABLE chat_server_attempt (project TEXT NOT NULL, uid TEXT NOT NULL, '
        'sid TEXT NOT NULL, chat TEXT NOT NULL, seq INTEGER NOT NULL, blocked INTEGER NOT NULL, '
        'PRIMARY KEY(project,uid,sid,chat))');
    await old.execute('PRAGMA user_version=3');
    await old.close();
    final db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    addTearDown(() async {
      await closeProjectChatServerDatabase(db);
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await dir.delete(recursive: true);
      }
    });
    final mode = await db.rawQuery('PRAGMA auto_vacuum');
    expect(mode.single.values.single, 0);
  });
}
