import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('denial and unfinished checks survive restart and concurrent stale allows', () async {
    final root = await Directory.systemTemp.createTemp('pin-fence-test-');
    final path = '${root.path}/fence.db';
    var db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    await db.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT NOT NULL, sid TEXT NOT NULL)');
    await db.insert('chat_app_guards', {'token': 'guard', 'project': '*', 'sid': ''});
    var fence = PinnedAccessFence(db, databaseToken: 'guard');
    const p = 'project', u = 'owner', k = 'file';
    expect(await fence.canRead(p, u, k), isFalse);
    final first = await fence.begin(p, u, k);
    expect(await fence.canRead(p, u, k), isFalse);
    await fence.finish(first, allowed: true);
    expect(await fence.canRead(p, u, k), isTrue);
    final oldAllow = await fence.begin(p, u, k);
    final denial = await fence.begin(p, u, k);
    await fence.finish(denial, allowed: false);
    await fence.finish(oldAllow, allowed: true);
    expect(await fence.canRead(p, u, k), isFalse);
    await db.close();
    db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    fence = PinnedAccessFence(db, databaseToken: 'guard');
    expect(await fence.canRead(p, u, k), isFalse);
    final retry = await fence.begin(p, u, k);
    await fence.finish(retry, allowed: null);
    expect(await fence.canRead(p, u, k), isFalse);
    final allow = await fence.begin(p, u, k);
    await fence.finish(allow, allowed: true);
    expect(await fence.canRead(p, u, k), isTrue);
    await fence.begin(p, u, k);
    await db.close();
    db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    expect(await PinnedAccessFence(db).canRead(p, u, k), isFalse);
    expect(await PinnedAccessFence(db).canRead('other', u, k), isFalse);
    await db.close(); await root.delete(recursive: true);
  });
}
