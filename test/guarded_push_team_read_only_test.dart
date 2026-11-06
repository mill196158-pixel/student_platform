import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/guarded_push_hint.dart';
import 'package:student_platform/src/services/push/guarded_push_qa_route.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const payload = PushPayload(
      version: 1,
      type: 'team_message',
      chatId: 'chat',
      teamId: 'untrusted',
      raw: {'title': 'untrusted title'});
  const summary = {
    'chat_id': 'chat',
    'chat_type': 'team_main',
    'team_id': 'team'
  };
  final row = {
    'id': 'message',
    'chat_id': 'chat',
    'author_id': 'peer',
    'created_at': '2026-01-01T00:00:00Z',
    'text': 'Текст команды',
    'type': 'text',
    'attachments': [],
    'has_more': false
  };

  testWidgets('resolved team route reads one page and closes on owner change',
      (tester) async {
    var generation = 1, calls = 0;
    final navigator = GlobalKey<NavigatorState>();
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      calls++;
      expect(request.url.path, endsWith('/rpc/get_chat_messages_page'));
      return http.Response(jsonEncode([row]), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: request);
    }));
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => generation == 1);
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const Scaffold(body: Text('Главная'))));
    await openGuardedPushHint(
        navigator: navigator.currentState!,
        payload: payload,
        barrier: barrier,
        isCurrent: () => generation == 1,
        fetchSummaries: () async => [summary],
        buildVerifiedTarget: (target) => buildGuardedPushQaTarget(
            incoming: payload,
            target: target,
            client: client,
            user: 'owner',
            barrier: barrier,
            current: () => generation == 1,
            dmEnabled: false,
            teamEnabled: true));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Чат команды'), findsOneWidget);
    expect(find.text('Текст команды'), findsOneWidget);
    expect(find.text('untrusted title'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(calls, 1);
    generation = 2;
    barrier.close();
    generation = 3;
    await tester.pump();
    expect(find.text('Текст команды'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Главная'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    unawaited(client.dispose());
  });
  testWidgets('group action remains neutral and never opens team page',
      (tester) async {
    const incoming =
        PushPayload(version: 1, type: 'collection_created', chatId: 'chat');
    const target = PushPayload(
        version: 1, type: 'team_message', chatId: 'chat', teamId: 'team');
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient:
            MockClient((_) async => throw StateError('unexpected request')));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    await tester.pumpWidget(MaterialApp(
        home: buildGuardedPushQaTarget(
            incoming: incoming,
            target: target,
            client: client,
            user: 'owner',
            barrier: barrier,
            current: () => true,
            dmEnabled: true,
            teamEnabled: true)));
    expect(find.textContaining('разделе «Сообщения»'), findsOneWidget);
    expect(find.text('Чат команды'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(client.dispose());
  });
  testWidgets(
      'team delayed response is drained and never displayed after A to B to A',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
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
        navigatorKey: navigator, home: const Scaffold(body: Text('Главная'))));
    await openGuardedPushHint(
        navigator: navigator.currentState!,
        payload: payload,
        barrier: barrier,
        isCurrent: () => generation == 1,
        fetchSummaries: () async => [summary],
        buildVerifiedTarget: (target) => buildGuardedPushQaTarget(
            incoming: payload,
            target: target,
            client: client,
            user: 'owner',
            barrier: barrier,
            current: () => generation == 1,
            dmEnabled: false,
            teamEnabled: true));
    await tester.pump();
    expect(barrier.activeCount, 1);
    generation = 2;
    barrier.close();
    generation = 3;
    expect(await barrier.closeAndDrain(timeout: Duration.zero), isFalse);
    final drain = barrier.closeAndDrain(timeout: const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Текст команды'), findsNothing);
    response.complete(http.Response(jsonEncode([row]), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    for (var i = 0; i < 20 && barrier.activeCount != 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(barrier.activeCount, 0);
    expect(await drain, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Текст команды'), findsNothing);
    expect(find.text('Главная'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(client.dispose());
  });
  testWidgets('team server denial does not become an empty history',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({'message': 'forbidden'}), 403,
            headers: {'content-type': 'application/json'}, request: request)));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()));
    await openGuardedPushHint(
        navigator: navigator.currentState!,
        payload: payload,
        barrier: barrier,
        isCurrent: () => true,
        fetchSummaries: () async => [summary],
        buildVerifiedTarget: (target) => buildGuardedPushQaTarget(
            incoming: payload,
            target: target,
            client: client,
            user: 'owner',
            barrier: barrier,
            current: () => true,
            dmEnabled: false,
            teamEnabled: true));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Сообщения недоступны.'), findsOneWidget);
    expect(find.text('Сообщений пока нет'), findsNothing);
    barrier.close();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    unawaited(client.dispose());
  });
}
