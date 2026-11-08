import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_authorizer.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_store.dart';

class _FailDenialOnce extends PinnedAccessFence {
  _FailDenialOnce(super.db) : super(databaseToken: 'guard');
  bool fail = true;
  @override
  Future<void> finish(String token, {required bool? allowed}) async {
    if (allowed == false && fail) {
      fail = false;
      throw StateError('injected denial write failure');
    }
    return super.finish(token, allowed: allowed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('late denial remains fenced and cancelled source cannot mint a grant',
      () async {
    final root = await Directory.systemTemp.createTemp('source-auth-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/test.db');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.execute(
        'CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT NOT NULL, sid TEXT NOT NULL)');
    await db.insert(
        'chat_app_guards', {'token': 'guard', 'project': '*', 'sid': ''});
    await db.execute(
        'CREATE TABLE chat_server_attempt (project TEXT, uid TEXT, sid TEXT, chat TEXT, seq INTEGER, blocked INTEGER)');
    await db.execute(
        'CREATE TABLE chat_server_snapshot (project TEXT, uid TEXT, sid TEXT, chat TEXT, payload TEXT)');
    await db.execute(
        'CREATE TABLE media_cache_logout_tombstones (project TEXT, uid TEXT, sid TEXT)');
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
    const source = SourceAttachmentIdentity(
        project: 'p',
        uid: 'u',
        sid: 's',
        chatId: 'c',
        messageId: 'm',
        fileId: 'f',
        fileKey: 'key',
        fileUrl: 'https://storage.test/key');
    final fence = PinnedAccessFence(db, databaseToken: 'guard');
    String? keyFor(String value) {
      final uri = Uri.tryParse(value);
      return uri != null &&
              uri.scheme == 'https' &&
              uri.host == 'storage.test' &&
              uri.path == '/key'
          ? 'key'
          : null;
    }

    final authorizer = SourceBoundAuthorizer(
        guard: SourceAttachmentGuard(db),
        fence: fence,
        storageHost: 'storage.test',
        keyForUrl: keyFor);
    const allow = SourceAccessResponse.allow(
        fileId: 'f', key: 'key', signedUrl: 'https://storage.test/key');
    var current = true;
    for (final bad in [
      'https://other.test/key',
      'http://storage.test/key',
      'https://storage.test/other'
    ]) {
      expect(
          await authorizer.authorize(
              source,
              () => current,
              () async => SourceAccessResponse.allow(
                  fileId: 'f', key: 'key', signedUrl: bad)),
          isNull);
    }
    final first =
        await authorizer.authorize(source, () => current, () async => allow);
    expect(first, isNotNull);
    expect(await fence.canRead('p', 'u', 'key'), isFalse);
    final store = SourceBoundDocumentStore(SourceAttachmentGuard(db), fence);
    final mutable = Uint8List.fromList([4, 5, 6]);
    final publishing = store.publish(source, () => current, first!, mutable);
    mutable[0] = 9;
    expect(await publishing, isTrue);
    expect(await store.read(source, () => current), [4, 5, 6]);
    expect(await fence.canRead('p', 'u', 'key'), isTrue);
    await db.delete('source_bound_proofs');
    expect(await store.read(source, () => current), isNull,
        reason: 'an older blob without source proof cannot be promoted');
    expect(await db.query('source_bound_documents'), hasLength(1),
        reason: 'older bytes are retained for safe recovery');
    final confirm =
        await authorizer.authorize(source, () => current, () async => allow);
    expect(
        await store.publish(
            source, () => current, confirm!, Uint8List.fromList([4, 5, 6])),
        isTrue);
    await db.update('source_bound_documents', {
      'bytes': Uint8List.fromList([9, 9, 9])
    });
    expect(await store.read(source, () => current), isNull);
    await db.update('source_bound_documents', {
      'bytes': Uint8List.fromList([4, 5, 6])
    });
    final failing = _FailDenialOnce(db);
    final failAuthorizer = SourceBoundAuthorizer(
        guard: SourceAttachmentGuard(db),
        fence: failing,
        storageHost: 'storage.test',
        keyForUrl: keyFor);
    expect(
        await failAuthorizer.authorize(source, () => current,
            () async => const SourceAccessResponse.deny()),
        isNull);
    expect(await fence.canRead('p', 'u', 'key'), isFalse);
    await db
        .transaction((txn) => PinnedAccessFence.recoverHandle(txn, 'guard'));
    expect(await fence.canRead('p', 'u', 'key'), isFalse);
    final restore =
        await authorizer.authorize(source, () => current, () async => allow);
    expect(
        await store.publish(
            source, () => current, restore!, Uint8List.fromList([4, 5, 6])),
        isTrue);
    final stale =
        await authorizer.authorize(source, () => current, () async => allow);
    final snapshot =
        (await db.query('chat_server_snapshot')).single['payload'] as String;
    final changed = jsonDecode(snapshot) as List;
    (changed.single as Map)['content'] = 'changed without sequence increment';
    await db.update('chat_server_snapshot', {'payload': jsonEncode(changed)});
    expect(
        await store.publish(
            source, () => current, stale!, Uint8List.fromList([7])),
        isFalse);
    expect(await store.read(source, () => current), [4, 5, 6]);
    // A second engine can deny while an older generic check is in flight.
    // Neither its late success nor a new generic allow revalidates the blob.
    final otherDb = await databaseFactoryFfi.openDatabase(
        '${root.path}/test.db',
        options: OpenDatabaseOptions(singleInstance: false));
    await otherDb.insert(
        'chat_app_guards', {'token': 'other-guard', 'project': '*', 'sid': ''});
    final otherFence = PinnedAccessFence(otherDb, databaseToken: 'other-guard');
    final oldGeneric = await fence.begin('p', 'u', 'key');
    final denial = await otherFence.begin('p', 'u', 'key');
    await otherFence.finish(denial, allowed: false);
    await fence.finish(oldGeneric, allowed: true);
    expect(await store.read(source, () => current), isNull);
    final genericAllow = await otherFence.begin('p', 'u', 'key');
    await otherFence.finish(genericAllow, allowed: true);
    expect(await fence.canRead('p', 'u', 'key'), isTrue);
    expect(await store.read(source, () => current), isNull,
        reason: 'generic allow does not attest to the saved source bytes');
    final revalidated =
        await authorizer.authorize(source, () => current, () async => allow);
    expect(
        await store.publish(
            source, () => current, revalidated!, Uint8List.fromList([4, 5, 6])),
        isTrue);
    expect(await store.read(source, () => current), [4, 5, 6]);
    await otherDb.close();
    final late = Completer<SourceAccessResponse>();
    expect(
        await authorizer.authorize(source, () => current, () => late.future,
            timeout: const Duration(milliseconds: 1)),
        isNull);
    expect(await fence.canRead('p', 'u', 'key'), isFalse);
    late.complete(const SourceAccessResponse.deny());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await fence.canRead('p', 'u', 'key'), isFalse);
    final cancelled = Completer<SourceAccessResponse>();
    final pending =
        authorizer.authorize(source, () => current, () => cancelled.future);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    current = false;
    cancelled.complete(allow);
    expect(await pending, isNull);
    expect(await fence.canRead('p', 'u', 'key'), isFalse);
    current = true;
    await db.insert('media_cache_logout_tombstones',
        {'project': 'p', 'uid': 'u', 'sid': 's'});
    expect(await store.read(source, () => current), isNull);
  });
}
