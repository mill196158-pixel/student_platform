import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('unknown files stay protected; pinned file gets owner-scoped durable read lease', () async {
    final root = await Directory.systemTemp.createTemp('media-protection-');
    final databasePath = '${root.path}/index.db';
    final db = await databaseFactoryFfi.openDatabase(databasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    var owner = 'a';
    final registry = MediaCacheProtection(db: db, root: root, project: 'project',
        databaseToken: 'guard', currentOwner: () => owner);
    addTearDown(() async {
      await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) await root.delete(recursive: true);
    });
    await registry.initialize();
    final dir = Directory('${root.path}/authorized_chat_files/a');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${registry.digest('a', 'chats/file')}');
    await file.writeAsBytes([1, 2, 3]);
    expect(await registry.acquireRead('a', 'chats/file', () => true), isNull);
    expect(await registry.registerPinned('a', 'chats/file', () => true), isTrue);
    final token = await registry.acquireRead('a', 'chats/file', () => true);
    expect(token, isNotNull);
    expect((await db.query('media_cache_objects')).single['pinned'], 1);
    expect(await db.query('media_cache_read_leases'), hasLength(1));
    expect(await registry.evict('a', 1, allOperationsParticipate: true, permit: () => true), 0);
    expect(await registry.unpin('a', 'chats/file', explicitlyAllowed: false, permit: () => true), isFalse);
    expect(await registry.unpin('a', 'chats/file', explicitlyAllowed: true, permit: () => true), isTrue);
    expect(await registry.evict('a', 1, allOperationsParticipate: true, permit: () => true), 0);
    owner = 'b';
    expect(await registry.acquireRead('a', 'chats/file', () => true), isNull);
    await registry.releaseRead('a', 'chats/file', token!);
    expect(await db.query('media_cache_read_leases'), isEmpty);
    expect(await file.readAsBytes(), [1, 2, 3]);
    owner = 'a';
    expect(await registry.evict('a', 1, allOperationsParticipate: false, permit: () => true), 0);
    final removed = await registry.evict('a', 1, allOperationsParticipate: true, permit: () => true);
    expect(removed, const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA') ? 3 : 0);
    expect(await file.exists(), !const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA'));
    expect(await registry.registerPinned('../escape', 'chats/file', () => true), isFalse);
  });

  test('prewarmed owner lease protects in-flight reads until they drain', () async {
    final root = await Directory.systemTemp.createTemp('media-window-');
    final databasePath = '${root.path}/index.db';
    final db = await databaseFactoryFfi.openDatabase(databasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    var owner = 'a';
    final registry = MediaCacheProtection(db: db, root: root, project: 'project',
        databaseToken: 'guard', currentOwner: () => owner);
    addTearDown(() async {
      await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) await root.delete(recursive: true);
    });
    await registry.initialize();
    await db.execute('CREATE TABLE chat_app_guards (token TEXT NOT NULL, project TEXT NOT NULL)');
    await db.insert('chat_app_guards', {'token': 'guard', 'project': '*'});
    final dir = Directory('${root.path}/authorized_chat_files/a');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${registry.digest('a', 'chats/file')}');
    await file.writeAsBytes([1, 2, 3]);
    expect(await registry.registerPinned('a', 'chats/file', () => true), isTrue);
    expect(await registry.unpin('a', 'chats/file', explicitlyAllowed: true, permit: () => true), isTrue);
    expect(await registry.beginOwnerReadWindow('a', () => true), isTrue);
    final otherDb = await databaseFactoryFfi.openDatabase(databasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final other = MediaCacheProtection(db: otherDb, root: root, project: 'project',
        databaseToken: 'other-guard', currentOwner: () => owner);
    expect(await other.evict('a', 1, allOperationsParticipate: true, permit: () => true), 0);
    await otherDb.close();
    final started = Completer<void>(), finish = Completer<void>();
    final reading = registry.readInOwnerWindow('a', () => true, () async {
      started.complete(); await finish.future; return file.readAsBytes();
    });
    await started.future;
    final ending = registry.endOwnerReadWindow('a');
    expect(registry.hasOwnerReadWindow('a', () => true), isFalse);
    expect(await registry.evict('a', 1, allOperationsParticipate: true, permit: () => true), 0);
    finish.complete();
    expect(await reading, [1, 2, 3]);
    await ending;
    expect(await registry.beginOwnerReadWindow('a', () => true), isTrue);
    final revokedStarted = Completer<void>(), revokedFinish = Completer<void>();
    final revokedRead = registry.readInOwnerWindow('a', () => true, () async {
      revokedStarted.complete(); await revokedFinish.future; return file.readAsBytes();
    });
    await revokedStarted.future;
    owner = 'b';
    revokedFinish.complete();
    await expectLater(revokedRead, throwsStateError);
    await registry.endOwnerReadWindow('a');
    owner = 'a';
    expect(await registry.evict('a', 1, allOperationsParticipate: true, permit: () => true),
        const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA') ? 3 : 0);
    owner = 'b';
    expect(await registry.beginOwnerReadWindow('a', () => true), isFalse);
    owner = 'a';
    final inserted = Completer<void>(), allowCommit = Completer<void>();
    registry.debugAfterWindowInsert = () async { inserted.complete(); await allowCommit.future; };
    final pending = registry.beginOwnerReadWindow('a', () => true);
    await inserted.future;
    await registry.endOwnerReadWindow('a');
    allowCommit.complete();
    expect(await pending, isFalse);
    expect(await db.query('media_cache_read_leases'), isEmpty);
  });
}
