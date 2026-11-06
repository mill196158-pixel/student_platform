import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final rows = [
    {
      'id': 'message',
      'chat_id': 'chat',
      'author_id': 'peer',
      'created_at': '2026-01-01T00:00:00Z',
      'text': 'Проверенный текст',
      'type': 'text',
      'attachments': [],
      'has_more': false,
    }
  ];
  testWidgets(
      'real direct screen loads only confirmed page and hides on revoke',
      (tester) async {
    expect(
        DmApi.parseConfirmedMessagesPage(rows, 'chat', limit: 50)
            .messages
            .single
            .text,
        'Проверенный текст');
    var requests = 0, current = true;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      requests++;
      expect(request.url.path, endsWith('/rpc/get_chat_messages_page'));
      return http.Response(jsonEncode(rows), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: request);
    }));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => current);
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
            peerId: 'peer',
            peerName: 'ignored',
            initialChatId: 'chat',
            guardedPushClient: client,
            guardedPushUserId: 'owner',
            onlineBarrier: barrier,
            sessionIsCurrent: () => current)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Проверенный текст'), findsOneWidget);
    expect(find.textContaining('Отправка и вложения'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage),
        findsNothing);
    expect(requests, 1);
    current = false;
    barrier.close();
    await tester.pump();
    expect(find.text('Проверенный текст'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    // The synthetic Supabase realtime client does not settle dispose in widget fake-async.
    unawaited(client.dispose());
  });
  testWidgets(
      'late page across owner ABA cannot render and drain awaits transport',
      (tester) async {
    final response = Completer<http.Response>();
    var generation = 1;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      final result = await response.future;
      return http.Response(result.body, result.statusCode,
          headers: result.headers, request: request);
    }));
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => generation == 1);
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
            peerId: 'peer',
            peerName: '',
            initialChatId: 'chat',
            guardedPushClient: client,
            guardedPushUserId: 'owner',
            onlineBarrier: barrier,
            sessionIsCurrent: () => generation == 1)));
    await tester.pump();
    expect(barrier.activeCount, 1);
    generation = 2;
    barrier.close();
    generation = 3;
    final drain = barrier.closeAndDrain(timeout: const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Проверенный текст'), findsNothing);
    response.complete(http.Response(jsonEncode(rows), 200,
        headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 20 && barrier.activeCount != 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(barrier.activeCount, 0);
    expect(await drain, isTrue);
    expect(find.text('Проверенный текст'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    // The synthetic Supabase realtime client does not settle dispose in widget fake-async.
    unawaited(client.dispose());
  });
  testWidgets(
      'literal forward marker remains visible and incomplete history is disclosed',
      (tester) async {
    final values = [
      {
        ...rows.single,
        'id': 'literal',
        'text': 'Текст __FG__: как написано',
        'has_more': true
      },
      {
        ...rows.single,
        'id': 'forward',
        'text': '__FG__:{"fg":1,"from":"source","items":[{"id":"message-1"}]}',
        'has_more': true
      },
    ];
    values.add({
      ...rows.single,
      'id': 'literal-json',
      'text': '__FG__:{}',
      'has_more': true
    });
    values.add({
      ...rows.single,
      'id': 'literal-numbers',
      'text': '__FG__:{"fg":1,"from":123,"items":[{"id":456}]}',
      'has_more': true
    });
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            jsonEncode(values), 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
            request: request)));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
            peerId: 'peer',
            peerName: '',
            initialChatId: 'chat',
            guardedPushClient: client,
            guardedPushUserId: 'owner',
            onlineBarrier: barrier,
            sessionIsCurrent: () => true)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Текст __FG__: как написано'), findsOneWidget);
    expect(find.text('__FG__:{}'), findsOneWidget);
    expect(find.text('__FG__:{"fg":1,"from":123,"items":[{"id":456}]}'),
        findsOneWidget);
    expect(
        find.textContaining('более ранние здесь недоступны'), findsOneWidget);
    expect(find.textContaining('"from":"source"'), findsNothing);
    barrier.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    unawaited(client.dispose());
  });
  testWidgets(
      'incomplete history is disclosed even when all messages are unavailable',
      (tester) async {
    final values = [
      {
        ...rows.single,
        'text': '__FG__:{"fg":1,"from":"source","items":[{"id":"message-1"}]}',
        'has_more': true
      }
    ];
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            jsonEncode(values), 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
            request: request)));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
            peerId: 'peer',
            peerName: '',
            initialChatId: 'chat',
            guardedPushClient: client,
            guardedPushUserId: 'owner',
            onlineBarrier: barrier,
            sessionIsCurrent: () => true)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(
        find.textContaining('более ранние здесь недоступны'), findsOneWidget);
    expect(find.text('Некоторые сообщения недоступны в этом просмотре.'),
        findsOneWidget);
    barrier.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    unawaited(client.dispose());
  });
}
