import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
      'failed eviction restores the file and pins it; a concurrent reader cannot enter',
      () async {
    final root = await Directory.systemTemp.createTemp('student-media-evict-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/test.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final otherDb = await databaseFactoryFfi.openDatabase(
        '${root.path}/test.db',
        options: OpenDatabaseOptions(singleInstance: false));
    var owner = 'owner';
    final store = MediaCacheProtection(
        db: db,
        root: root,
        project: 'project',
        databaseToken: 'test-guard',
        currentOwner: () => owner,
        currentSessionId: () => 'sid');
    final other = MediaCacheProtection(
        db: otherDb,
        root: root,
        project: 'project',
        databaseToken: 'other-guard',
        currentOwner: () => owner,
        currentSessionId: () => 'sid');
    addTearDown(() async {
      await otherDb.close();
      await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path)
        await root.delete(recursive: true);
    });
    await store.initialize();
    final dir = Directory('${root.path}/authorized_chat_files/owner');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${store.digest('owner', 'key')}');
    await file.writeAsBytes([10, 20, 30], flush: true);
    expect(await store.registerPinned('owner', 'key', () => true), isTrue);
    expect(
        await store.unpin('owner', 'key',
            explicitlyAllowed: true, permit: () => true),
        isTrue);
    final staged = Completer<void>(), finish = Completer<void>();
    store.debugAfterEvictionRename = () async {
      staged.complete();
      await finish.future;
      throw StateError('synthetic failure');
    };
    final result = store.evict('owner', 1,
        allOperationsParticipate: true, permit: () => true);
    await staged.future;
    expect(await other.acquireRead('owner', 'key', () => true), isNull);
    expect(await db.query('media_cache_eviction_journal'), hasLength(1));
    finish.complete();
    expect(await result, 0);
    expect(await file.readAsBytes(), [10, 20, 30]);
    expect((await db.query('media_cache_objects')).single['pinned'], 1);
    expect(await db.query('media_cache_eviction_journal'), isEmpty);
  }, skip: !const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA'));

  test('reopen restores staged file only after its handle guard is removed',
      () async {
    final root =
        await Directory.systemTemp.createTemp('student-media-recover-');
    final path = '${root.path}/test.db';
    var db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    MediaCacheProtection create() => MediaCacheProtection(
        db: db,
        root: root,
        project: 'project',
        databaseToken: 'new-guard',
        currentOwner: () => 'owner',
        currentSessionId: () => 'sid');
    var store = create();
    addTearDown(() async {
      await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path)
        await root.delete(recursive: true);
    });
    await store.initialize();
    await db.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY)');
    await db.insert('chat_app_guards', {'token': 'old-guard'});
    final dir = Directory('${root.path}/authorized_chat_files/owner');
    await dir.create(recursive: true);
    final hash = store.digest('owner', 'key');
    const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    final original = File('${dir.path}/$hash');
    final staged = File('${dir.path}/.evict-$token-$hash');
    await original.writeAsBytes([7, 8], flush: true);
    expect(await store.registerPinned('owner', 'key', () => true), isTrue);
    await db.insert('media_cache_eviction_journal', {
      'token': token,
      'project': 'project',
      'uid': 'owner',
      'digest': hash,
      'database_token': 'old-guard',
      'sid': 'sid',
      'state': 'staging',
      'size': 2
    });
    await original.rename(staged.path);
    await db.close();
    db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    store = create();
    expect(await store.recoverInterruptedEvictions('owner', () => true), 0);
    expect(await staged.exists(), isTrue);
    await db
        .delete('chat_app_guards', where: 'token=?', whereArgs: ['old-guard']);
    expect(await store.recoverInterruptedEvictions('owner', () => true), 0);
    expect(
        await store.recoverInterruptedEvictions('owner', () => true,
            mayRestore: (token) => token == 'old-guard'),
        1);
    expect(await original.readAsBytes(), [7, 8]);
    expect(await staged.exists(), isFalse);
    expect((await db.query('media_cache_objects')).single['pinned'], 1);
    expect(await db.query('media_cache_eviction_journal'), isEmpty);
  });
  test(
      'shared legacy path is not evicted while another project owns or reads it',
      () async {
    final root = await Directory.systemTemp.createTemp('student-media-shared-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/test.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final first = MediaCacheProtection(
        db: db,
        root: root,
        project: 'first',
        databaseToken: 'guard',
        currentOwner: () => 'owner',
        currentSessionId: () => 'sid');
    final second = MediaCacheProtection(
        db: db,
        root: root,
        project: 'second',
        databaseToken: 'guard',
        currentOwner: () => 'owner',
        currentSessionId: () => 'sid');
    addTearDown(() async {
      await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path)
        await root.delete(recursive: true);
    });
    await first.initialize();
    final dir = Directory('${root.path}/authorized_chat_files/owner');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${first.digest('owner', 'key')}');
    await file.writeAsBytes([4, 5, 6]);
    expect(await first.registerPinned('owner', 'key', () => true), isTrue);
    expect(await second.registerPinned('owner', 'key', () => true), isTrue);
    expect(
        await first.unpin('owner', 'key',
            explicitlyAllowed: true, permit: () => true),
        isTrue);
    expect(
        await first.evict('owner', 1,
            allOperationsParticipate: true, permit: () => true),
        0);
    expect(await file.readAsBytes(), [4, 5, 6]);
  }, skip: !const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA'));
  test('logout during a staged eviction never restores to a later A session',
      () async {
    final root = await Directory.systemTemp.createTemp('student-media-logout-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/test.db',
        options: OpenDatabaseOptions(singleInstance: false));
    var owner = 'a';
    var sameSession = true;
    final store = MediaCacheProtection(
        db: db,
        root: root,
        project: 'project',
        databaseToken: 'old-session',
        currentOwner: () => owner,
        currentSessionId: () => 'sid');
    addTearDown(() async {
      await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path)
        await root.delete(recursive: true);
    });
    await store.initialize();
    await db.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY)');
    final dir = Directory('${root.path}/authorized_chat_files/a');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${store.digest('a', 'key')}');
    await file.writeAsBytes([4, 5, 6]);
    expect(await store.registerPinned('a', 'key', () => sameSession), isTrue);
    expect(
        await store.unpin('a', 'key',
            explicitlyAllowed: true, permit: () => sameSession),
        isTrue);
    final staged = Completer<void>(), finish = Completer<void>();
    store.debugAfterEvictionRename = () async {
      staged.complete();
      await finish.future;
    };
    final operation = store.evict('a', 1,
        allOperationsParticipate: true, permit: () => sameSession);
    await staged.future;
    sameSession = false;
    owner = 'b';
    finish.complete();
    expect(await operation, 0);
    expect(await file.exists(), isFalse);
    expect(await db.query('media_cache_eviction_journal'), hasLength(1));
    owner = 'a';
    expect(await store.recoverInterruptedEvictions('a', () => true), 0);
    expect(await file.exists(), isFalse);
    expect(await db.query('media_cache_eviction_journal'), hasLength(1));
  }, skip: !const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA'));
}
