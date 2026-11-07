import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_authorizer.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_store.dart';
import 'package:student_platform/src/ui/chats/core/source_snapshot_attachment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('attached snapshot and fence transaction excludes a second writer',
      () async {
    final root = await Directory.systemTemp.createTemp('source-attach-');
    final mediaPath = '${root.path}/media.db',
        chatPath = '${root.path}/chat.db';
    final media = await databaseFactoryFfi.openDatabase(mediaPath,
        options: OpenDatabaseOptions(singleInstance: false));
    final mediaRival = await databaseFactoryFfi.openDatabase(mediaPath,
        options: OpenDatabaseOptions(singleInstance: false));
    final chat = await databaseFactoryFfi.openDatabase(chatPath,
        options: OpenDatabaseOptions(singleInstance: false));
    final wrong = await databaseFactoryFfi.openDatabase('${root.path}/wrong.db',
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async {
      await wrong.close();
      await mediaRival.close();
      await media.close();
      await chat.close();
      await root.delete(recursive: true);
    });
    await media.execute('PRAGMA journal_mode=WAL');
    await chat.execute('PRAGMA journal_mode=WAL');
    await media.execute(
        'CREATE TABLE fence (id INTEGER PRIMARY KEY, blocked INTEGER)');
    await media.insert('fence', {'id': 1, 'blocked': 0});
    await media.execute(
        'CREATE TABLE media_cache_logout_tombstones (project TEXT, uid TEXT, sid TEXT)');
    await media.execute(
        'CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT, sid TEXT)');
    await media.insert(
        'chat_app_guards', {'token': 'guard', 'project': '*', 'sid': ''});
    await chat.execute(
        'CREATE TABLE chat_server_attempt (project TEXT, uid TEXT, sid TEXT, chat TEXT, seq INTEGER, blocked INTEGER)');
    await chat.execute(
        'CREATE TABLE chat_server_snapshot (project TEXT, uid TEXT, sid TEXT, chat TEXT, payload TEXT)');
    await chat.insert('chat_server_attempt', {
      'project': 'p',
      'uid': 'u',
      'sid': 's',
      'chat': 'c',
      'seq': 1,
      'blocked': 0
    });
    await chat.insert('chat_server_snapshot', {
      'project': 'p',
      'uid': 'u',
      'sid': 's',
      'chat': 'c',
      'payload': jsonEncode([
        {
          'id': 'm',
          'chat_id': 'c',
          'delivery_status': 'sent',
          'attachments': [
            {
              'id': 'f',
              'chat_id': 'c',
              'message_id': 'm',
              'file_key': 'key',
              'file_url': 'https://storage.test/key',
              'is_deleted': false,
              'deletion_verified': true
            }
          ]
        }
      ])
    });
    final attachedPath = await attachSourceSnapshot(media, chat);
    expect(attachedPath, isNotNull);
    expect(await attachSourceSnapshot(media, wrong), isNull);
    const source = SourceAttachmentIdentity(
        project: 'p',
        uid: 'u',
        sid: 's',
        chatId: 'c',
        messageId: 'm',
        fileId: 'f',
        fileKey: 'key',
        fileUrl: 'https://storage.test/key');
    final guard = SourceAttachmentGuard(media,
        attachedSnapshot: true, attachedSnapshotPath: attachedPath);
    expect(
        await SourceAttachmentGuard(media,
                attachedSnapshot: true, attachedSnapshotPath: wrong.path)
            .capture(source, () => true),
        isNull);
    final entered = Completer<void>(), release = Completer<void>();
    final tx = guard.run(source, () => true, (txn, seq) async {
      expect(seq, 1);
      final fence =
          await txn.rawQuery('SELECT blocked FROM main.fence WHERE id=1');
      expect(fence.single['blocked'], 0);
      await txn.update('fence', {'blocked': 1}, where: 'id=1');
      entered.complete();
      await release.future;
      return true;
    });
    await entered.future;
    final rival = chat.update('chat_server_attempt', {'seq': 2}).then(
        (_) => true,
        onError: (Object _) => false);
    final beforeCommit = await Future.any<bool?>([
      rival,
      Future<bool?>.delayed(const Duration(milliseconds: 100), () => null),
    ]);
    expect(beforeCommit, isNot(isTrue),
        reason: 'snapshot must not change while the transaction is open');
    release.complete();
    expect(await tx, isTrue);
    final success = await rival;
    if (!success) await chat.update('chat_server_attempt', {'seq': 2});
    expect((await chat.query('chat_server_attempt')).single['seq'], 2);
    expect(
        await guard.run(source, () => true, (_, __) async => true,
            expectedSequence: 1),
        isNull);
    expect((await media.query('fence')).single['blocked'], 1);
    final fence = PinnedAccessFence(media, databaseToken: 'guard');
    final rivalFence = PinnedAccessFence(mediaRival, databaseToken: 'guard');
    final authorizer = SourceBoundAuthorizer(
        guard: guard,
        fence: fence,
        storageHost: 'storage.test',
        keyForUrl: (_) => 'key');
    final store = SourceBoundDocumentStore(guard, fence);
    const allow = SourceAccessResponse.allow(
        fileId: 'f', key: 'key', signedUrl: 'https://storage.test/key');
    final staleGrant =
        await authorizer.authorize(source, () => true, () async => allow);
    final denied = await rivalFence.begin('p', 'u', 'key');
    await rivalFence.finish(denied, allowed: false);
    expect(
        await store.publish(
            source, () => true, staleGrant!, Uint8List.fromList([1])),
        isFalse);
    final freshGrant =
        await authorizer.authorize(source, () => true, () async => allow);
    expect(
        await store.publish(
            source, () => true, freshGrant!, Uint8List.fromList([4, 5, 6])),
        isTrue);
    expect(await store.read(source, () => true), [4, 5, 6]);
    await mediaRival.insert('media_cache_logout_tombstones',
        {'project': 'p', 'uid': 'u', 'sid': 's'});
    expect(await store.read(source, () => true), isNull);
  });
}
