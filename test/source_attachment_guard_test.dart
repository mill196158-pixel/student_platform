import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('exact snapshot identity, sequence, account and cancellation fence',
      () async {
    final root = await Directory.systemTemp.createTemp('source-guard-');
    final path = '${root.path}/test.db';
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final otherDb = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async {
      await otherDb.close();
      await db.close();
      await root.delete(recursive: true);
    });
    await db.execute(
        'CREATE TABLE chat_server_attempt (project TEXT, uid TEXT, sid TEXT, chat TEXT, seq INTEGER, blocked INTEGER)');
    await db.execute(
        'CREATE TABLE chat_server_snapshot (project TEXT, uid TEXT, sid TEXT, chat TEXT, payload TEXT)');
    await db.execute(
        'CREATE TABLE media_cache_logout_tombstones (project TEXT, uid TEXT, sid TEXT)');
    await db.execute('CREATE TABLE publication (value TEXT)');
    const id = SourceAttachmentIdentity(
        project: 'p',
        uid: 'u',
        sid: 's',
        chatId: 'c',
        messageId: 'm',
        fileId: 'f',
        fileKey: 'key',
        fileUrl: 'url');
    final payload = [
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
            'file_url': 'url',
            'is_deleted': false,
            'deletion_verified': true
          }
        ]
      }
    ];
    await db.insert('chat_server_attempt', {
      'project': 'p',
      'uid': 'u',
      'sid': 's',
      'chat': 'c',
      'seq': 3,
      'blocked': 0
    });
    await db.insert('chat_server_snapshot', {
      'project': 'p',
      'uid': 'u',
      'sid': 's',
      'chat': 'c',
      'payload': jsonEncode(payload)
    });
    final guard = SourceAttachmentGuard(db);
    var current = true;
    Future<String?> check({int? seq}) =>
        guard.run(id, () => current, (txn, version) async => 'ok',
            expectedSequence: seq);
    expect(await check(seq: 3), 'ok');
    expect(await check(seq: 2), isNull);
    final entered = Completer<void>();
    final release = Completer<void>();
    final publishing = guard.run(id, () => current, (txn, seq) async {
      await txn.insert('publication', {'value': 'allowed at snapshot'});
      entered.complete();
      await release.future;
      return true;
    });
    await entered.future;
    // SQLite may report SQLITE_BUSY immediately on a second connection.
    final invalidate = otherDb
        .update('chat_server_attempt', {'blocked': 1}).then((_) => true,
            onError: (Object _) => false);
    release.complete();
    expect(await publishing, isTrue);
    if (!await invalidate)
      await otherDb.update('chat_server_attempt', {'blocked': 1});
    expect(await check(), isNull);
    await db.update('chat_server_attempt', {'blocked': 0});
    await db.delete('publication');
    current = false;
    expect(await check(), isNull);
    current = true;
    final stale = await guard.run(id, () => current, (txn, version) async {
      await txn.insert('publication', {'value': 'must roll back'});
      current = false;
      return 'bad';
    });
    expect(stale, isNull);
    expect(await db.query('publication'), isEmpty);
    current = true;
    expect(
        await guard.run(id, () => current, (txn, version) async {
          await txn.update('chat_server_attempt', {'seq': version + 1});
          await txn.insert('publication', {'value': 'obsolete'});
          return true;
        }),
        isNull);
    expect((await db.query('chat_server_attempt')).single['seq'], 3);
    expect(await db.query('publication'), isEmpty);
    const other = SourceAttachmentIdentity(
        project: 'p',
        uid: 'other',
        sid: 's',
        chatId: 'c',
        messageId: 'm',
        fileId: 'f',
        fileKey: 'key',
        fileUrl: 'url');
    expect(await guard.run(other, () => true, (_, __) async => true), isNull);
    await db.update('chat_server_attempt', {'blocked': 1});
    expect(await check(), isNull);
    await db.update('chat_server_attempt', {'blocked': 0});
    final original = List.of(payload.single['attachments'] as List);
    payload.single['attachments'] = [...original, ...original];
    await db.update('chat_server_snapshot', {'payload': jsonEncode(payload)});
    expect(await check(), isNull);
    payload.single['attachments'] = [];
    await db.update('chat_server_snapshot', {'payload': jsonEncode(payload)});
    expect(await check(), isNull);
  });
}
