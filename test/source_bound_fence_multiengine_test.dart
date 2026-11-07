import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('independent pending checks and crash recovery remain fail closed', () async {
    final root = await Directory.systemTemp.createTemp('fence-engines-');
    final path = '${root.path}/shared.db';
    final a = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    final b = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    var bOpen = true;
    addTearDown(() async {
      if (bOpen) await b.close();
      await a.close();
      await root.delete(recursive: true);
    });
    await a.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT, sid TEXT)');
    for (final token in ['engine-a', 'engine-b']) {
      await a.insert('chat_app_guards', {'token': token, 'project': '*', 'sid': ''});
    }
    final first = PinnedAccessFence(a, databaseToken: 'engine-a');
    final second = PinnedAccessFence(b, databaseToken: 'engine-b');
    const project = 'project', uid = 'user', key = 'object';
    var token = await first.begin(project, uid, key);
    await first.finish(token, allowed: true);
    expect(await first.canRead(project, uid, key), isTrue);
    final early = await first.begin(project, uid, key);
    final late = await second.begin(project, uid, key);
    await first.finish(early, allowed: true);
    expect(await first.canRead(project, uid, key), isFalse);
    await second.finish(late, allowed: false);
    expect(await first.canRead(project, uid, key), isFalse);
    token = await first.begin(project, uid, key);
    await first.finish(token, allowed: true);
    expect(await first.canRead(project, uid, key), isTrue);
    await second.begin(project, uid, key);
    await b.close(); bOpen = false;
    expect(await first.canRead(project, uid, key), isFalse);
    // Test simulates a proved-dead database handle; production must first
    // confirm death using its OS process guard before calling recoverHandle.
    await a.transaction((txn) => PinnedAccessFence.recoverHandle(txn, 'engine-b'));
    expect(await first.canRead(project, uid, key), isFalse);
    token = await first.begin(project, uid, key);
    await a.transaction((txn) => first.markPinned(txn, project, uid, key, 'checksum'));
    await first.finish(token, allowed: true);
    expect(await first.canRead(project, uid, key, checksum: 'checksum'), isTrue);
  });
}
