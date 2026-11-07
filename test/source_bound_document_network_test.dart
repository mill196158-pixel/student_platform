import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_authorizer.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_network.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
      'network rechecks source and never publishes rejected or cancelled downloads',
      () async {
    final root = await Directory.systemTemp.createTemp('source-net-');
    final path = '${root.path}/test.db';
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final observer = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async {
      await observer.close();
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
      'seq': 1,
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
    var calls = 0;
    var mode = 'ok';
    Completer<http.Response>? late;
    final transport = MockClient((request) async {
      calls++;
      if (mode == 'deny-second' && calls == 2) {
        return http.Response(
            jsonEncode(
                {'error': 'file_unavailable', 'reason': 'access_denied_v1'}),
            403,
            headers: {'content-type': 'application/json'});
      }
      if (mode == 'unauthorized-second' && calls == 2) {
        return http.Response('{"error":"unauthorized"}', 401,
            headers: {'content-type': 'application/json'});
      }
      if (mode == 'timeout-second' && calls == 2) return late!.future;
      if (mode == 'wrong-key-second' && calls == 2) {
        return http.Response(
            jsonEncode({
              'fileId': 'f',
              'url': 'https://storage.test/other',
              'accessPolicyVersion': 1
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (mode == 'invalid')
        return http.Response('{"fileId":4}', 200,
            headers: {'content-type': 'application/json'});
      return http.Response(
          jsonEncode({
            'fileId': 'f',
            'url': 'https://storage.test/key',
            'accessPolicyVersion': 1
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final client =
        SupabaseClient('https://example.test', 'test', httpClient: transport);
    addTearDown(client.dispose);
    final guard = SourceAttachmentGuard(db);
    final fence = PinnedAccessFence(db, databaseToken: 'guard');
    final store = SourceBoundDocumentStore(guard, fence);
    String? keyFor(String value) {
      final uri = Uri.tryParse(value);
      return uri != null &&
              uri.scheme == 'https' &&
              uri.host == 'storage.test' &&
              uri.path == '/key'
          ? 'key'
          : null;
    }

    final auth = SourceBoundAuthorizer(
        guard: guard,
        fence: fence,
        storageHost: 'storage.test',
        keyForUrl: keyFor);
    final network = SourceBoundDocumentNetwork(client, auth, store);
    var current = true;
    http.Client normal() =>
        MockClient((r) async => http.Response.bytes([4, 5, 6], 200));
    Future<bool> run({http.Client Function()? makeHttp}) =>
        network.download(source, () => current,
            makeHttp: makeHttp ?? normal,
            resolveTimeout: const Duration(milliseconds: 80));
    expect(await run(), isTrue);
    expect(await store.read(source, () => current), [4, 5, 6]);
    calls = 0;
    mode = 'unauthorized-second';
    expect(await run(), isFalse);
    expect(await store.read(source, () => current), [4, 5, 6]);
    calls = 0;
    mode = 'wrong-key-second';
    expect(await run(), isFalse);
    expect(await store.read(source, () => current), [4, 5, 6]);
    calls = 0;
    mode = 'deny-second';
    expect(await run(), isFalse);
    expect(await store.read(source, () => current), isNull);
    calls = 0;
    mode = 'ok';
    expect(await run(), isTrue);
    calls = 0;
    mode = 'invalid';
    expect(await run(), isFalse);
    expect(await store.read(source, () => current), [4, 5, 6]);
    calls = 0;
    mode = 'ok';
    expect(
        await run(
            makeHttp: () => MockClient((r) async => http.Response.bytes(
                List<int>.filled(SourceBoundDocumentStore.maxFileBytes + 1, 1),
                200))),
        isFalse);
    expect(await store.read(source, () => current), [4, 5, 6]);
    calls = 0;
    final watch = Stopwatch()..start();
    expect(
        await network.download(source, () => current,
            downloadTimeout: const Duration(milliseconds: 75),
            makeHttp: () => MockClient.streaming((request, body) async =>
                http.StreamedResponse(
                    Stream<List<int>>.periodic(
                        const Duration(milliseconds: 20), (_) => [1]).take(20),
                    200))),
        isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(await store.read(source, () => current), [4, 5, 6]);
    calls = 0;
    mode = 'timeout-second';
    late = Completer<http.Response>();
    expect(await run(), isFalse);
    expect(await store.read(source, () => current), isNull);
    late!.complete(http.Response(
        jsonEncode({'error': 'file_unavailable', 'reason': 'access_denied_v1'}),
        403,
        headers: {'content-type': 'application/json'}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await store.read(source, () => current), isNull);
    calls = 0;
    mode = 'ok';
    expect(await run(), isTrue);
    calls = 0;
    expect(
        await run(
            makeHttp: () => MockClient((r) async {
                  current = false;
                  return http.Response.bytes([9], 200);
                })),
        isFalse);
    current = true;
    expect(await store.read(source, () => current), [4, 5, 6]);
    await observer.insert('media_cache_logout_tombstones',
        {'project': 'p', 'uid': 'u', 'sid': 's'});
    expect(await store.read(source, () => current), isNull);
  });
}
