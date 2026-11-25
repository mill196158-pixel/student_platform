import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  test(
      'manual mark-read pages through the captured cursor and preserves a later message',
      () async {
    const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const cursor = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
    final marked = <String>[];
    var messages = true, cursorWrites = 0, pages = 0;
    final client = SupabaseClient('https://example.invalid', 'test',
        httpClient: MockClient((request) async {
      Object? response;
      switch (request.url.pathSegments.last) {
        case 'messages':
          response = messages
              ? [
                  {'id': cursor, 'created_at': '2026-11-25T09:00:00Z'}
                ]
              : [];
          break;
        case 'mark_chat_read':
          expect(jsonDecode(request.body)['p_message_id'], cursor);
          cursorWrites++;
          break;
        case 'app_notifications':
          pages++;
          if (pages == 1) {
            response = List.generate(
                50,
                (n) => {
                      'id': n.toString().padLeft(3, '0'),
                      'data': {'message_id': 'old$n'},
                      'created_at': '2026-11-25T08:00:00Z'
                    });
          } else {
            expect(request.url.queryParameters['id'], 'gt.049');
            response = [
              {
                'id': '050',
                'data': {'message_id': cursor},
                'created_at': '2026-11-25T09:00:02Z'
              },
              {
                'id': '051',
                'data': {'message_id': 'new'},
                'created_at': '2026-11-25T09:00:01Z'
              },
              for (final (row, message) in [
                ('052', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'),
                ('053', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3'),
                ('054', 'unknown'),
              ])
                {'id': row, 'data': {'message_id': message}, 'created_at': '2026-11-25T09:00:00Z'},
            ];
          }
          break;
        case 'mark_notification_read':
          marked.add(jsonDecode(request.body)['p_notification_id'] as String);
          break;
        default:
          fail('Unexpected local request');
      }
      return http.Response(jsonEncode(response), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    await signInWithFileSession(client, owner, owner);
    final api = AppNotificationsApi(client: client);
    await api.markLatestChatRead('chat', isCurrent: () => true);
    expect(marked.toSet(),
        {for (var i = 0; i <= 50; i++) i.toString().padLeft(3, '0'), '052'});
    expect((pages, cursorWrites), (2, 1));
    messages = false;
    await api.markLatestChatRead('empty-chat', isCurrent: () => true);
    expect((pages, cursorWrites), (2, 1));
  });
  test('drawer lookup requires a positive owned read row for the same session',
      () async {
    const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const other = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final row = {
      'id': id,
      'recipient_id': owner,
      'read_at': '2026-10-03T00:00:00Z'
    };
    List<Object> rows = [row];
    Future<void>? wait;
    final client = SupabaseClient('https://example.invalid', 'test',
        httpClient: MockClient((request) async {
      expect(request.url.path, '/rest/v1/app_notifications');
      expect(request.url.queryParameters['recipient_id'], 'eq.$owner');
      expect(request.url.queryParameters['id'], 'in.("$id")');
      expect(request.url.queryParameters['read_at'], 'not.is.null');
      await wait;
      return http.Response(jsonEncode(rows), 200,
          headers: {'content-type': 'application/json'}, request: request);
    }));
    addTearDown(client.dispose);
    final api = AppNotificationsApi(client: client);
    expect(await api.readDeliveredIds(owner, {id}), isEmpty);
    await signInWithFileSession(client, owner, owner);
    expect(await api.readDeliveredIds(owner, {id}), {id});
    rows = [];
    expect(await api.readDeliveredIds(owner, {id}), isEmpty);
    for (final bad in [
      {...row, 'recipient_id': other},
      {...row, 'id': other},
      {...row, 'read_at': null},
    ]) {
      rows = [bad];
      await expectLater(
          api.readDeliveredIds(owner, {id}), throwsFormatException);
    }
    rows = [row];
    final pending = Completer<void>();
    wait = pending.future;
    final old = api.readDeliveredIds(owner, {id});
    await signInWithFileSession(client, owner, other);
    pending.complete();
    expect(await old, isEmpty);
  });
  test('unread count distinguishes confirmed zero from errors', () async {
    var response = '5';
    var status = 200;
    final client = SupabaseClient('https://example.invalid', 'test',
        httpClient: MockClient((request) async => http.Response(
            response, status,
            headers: {'content-type': 'application/json'}, request: request)));
    final api = AppNotificationsApi(client: client);
    try {
      expect(await api.unreadCount(), 5);
      response = '0';
      expect(await api.unreadCount(), 0);
      response = 'null';
      await expectLater(api.unreadCount(), throwsFormatException);
      response = '-1';
      await expectLater(api.unreadCount(), throwsFormatException);
      response = '{"message":"unavailable"}';
      status = 500;
      await expectLater(api.unreadCount(), throwsA(isA<Exception>()));
    } finally {
      await client.dispose();
    }
  });

  test(
      'partial chat-read success only dismisses acknowledged ids and never survives session change',
      () async {
    const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const replacement = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final successes = <Set<String>?>[];
    Future<void>? wait;
    final client = SupabaseClient('https://example.invalid', 'test',
        httpClient: MockClient((request) async {
      if (request.url.path.endsWith('app_notifications')) {
        return http.Response('[{"id":"first"},{"id":"second"}]', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      expect(request.url.path, '/rest/v1/rpc/mark_notification_read');
      final id = jsonDecode(request.body)['p_notification_id'];
      await wait;
      return http.Response(
          id == 'first' ? 'null' : '{"message":"forbidden","code":"42501"}',
          id == 'first' ? 200 : 403,
          headers: {'content-type': 'application/json'},
          request: request);
    }));
    addTearDown(client.dispose);
    AppNotificationsApi.captureReadReceipt = (_) => successes.add;
    addTearDown(() => AppNotificationsApi.captureReadReceipt = null);
    final api = AppNotificationsApi(client: client);
    await signInWithFileSession(client, owner, owner);
    await expectLater(
        api.markReadForChat('chat'), throwsA(isA<PostgrestException>()));
    expect(successes, [
      {'first'}
    ]);
    final pending = Completer<void>();
    wait = pending.future;
    final old = api.markRead('first');
    await signInWithFileSession(client, owner, replacement);
    pending.complete();
    await old;
    expect(successes, [
      {'first'}
    ]);
  });
}
