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
import 'package:student_platform/src/ui/learning/tabs/chat/unified_task_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final valid = {
    'available': true,
    'kind': 'topic_selection',
    'details_kind': 'topic_selection',
    'entity_id': 'entity',
    'card_message_id': 'card',
    'title': 'Выбор темы',
    'description': 'Описание'
  };
  Widget screen(SupabaseClient client, OnlineSideEffectBarrier barrier,
          bool Function() current) =>
      MaterialApp(
          home: UnifiedTaskDetailsScreen(
              kind: 'topic_selection',
              entityId: 'entity',
              chatId: 'chat',
              cardMessageId: 'card',
              guardedPushClient: client,
              guardedPushBarrier: barrier,
              guardedPushSessionIsCurrent: current));
  testWidgets('actual action screen loads one scoped RPC without actions',
      (tester) async {
    var calls = 0;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      calls++;
      expect(request.url.path, endsWith('/rpc/get_task_details'));
      expect(jsonDecode(request.body), {
        'p_kind': 'topic_selection',
        'p_entity_id': 'entity',
        'p_chat_id': 'chat'
      });
      return http.Response(jsonEncode(valid), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: request);
    }));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    await tester.pumpWidget(screen(client, barrier, () => true));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Выбор темы'), findsOneWidget);
    expect(find.text('Описание'), findsOneWidget);
    expect(find.textContaining('без действий'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(calls, 1);
    barrier.close();
    await tester.pump();
    expect(find.text('Выбор темы'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    unawaited(client.dispose());
  });
  for (final invalid in [
    {...valid, 'available': false},
    {...valid, 'entity_id': 'other'},
    {...valid, 'kind': 'group_collection'},
    {...valid, 'card_message_id': 'other'},
    {...valid, 'card_message_id': ''},
    {...valid, 'title': null},
    {...valid, 'description': List.filled(4001, 'a').join()},
  ]) {
    testWidgets(
        'mismatched or malformed action response ${invalid.keys.join(',')} ${invalid['entity_id']} ${invalid['card_message_id']} ${invalid['available']}',
        (tester) async {
      final client = SupabaseClient('https://example.invalid', 'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async => http.Response(
              jsonEncode(invalid), 200,
              headers: {'content-type': 'application/json; charset=utf-8'},
              request: request)));
      final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
      await tester.pumpWidget(screen(client, barrier, () => true));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('Карточка недоступна.'), findsOneWidget);
      expect(find.text('Выбор темы'), findsNothing);
      barrier.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      unawaited(client.dispose());
    });
  }
  testWidgets('late action response is hidden and drain waits for response',
      (tester) async {
    final response = Completer<http.Response>();
    var generation = 1;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      final r = await response.future;
      return http.Response(r.body, r.statusCode,
          headers: r.headers, request: request);
    }));
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => generation == 1);
    await tester.pumpWidget(screen(client, barrier, () => generation == 1));
    await tester.pump();
    expect(barrier.activeCount, 1);
    generation = 2;
    barrier.close();
    generation = 3;
    expect(await barrier.closeAndDrain(timeout: Duration.zero), isFalse);
    final drain = barrier.closeAndDrain(timeout: const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Выбор темы'), findsNothing);
    response.complete(http.Response(jsonEncode(valid), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    for (var i = 0; i < 20 && barrier.activeCount != 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(barrier.activeCount, 0);
    expect(await drain, isTrue);
    expect(find.text('Выбор темы'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(client.dispose());
  });
  for (final kind in ['topic_selection', 'group_collection']) {
    testWidgets(
        'summary to actual $kind action route is scoped and closes on revoke',
        (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      var current = true, calls = 0;
      final incoming = PushPayload(
          version: 1,
          type: kind == 'topic_selection'
              ? 'topic_selection_created'
              : 'collection_created',
          chatId: 'chat',
          selectionId: kind == 'topic_selection' ? 'entity' : null,
          collectionId: kind == 'group_collection' ? 'entity' : null,
          cardMessageId: 'card',
          raw: const {'title': 'UNTRUSTED'});
      final response = {...valid, 'kind': kind, 'details_kind': kind};
      final client = SupabaseClient('https://example.invalid', 'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
        calls++;
        expect(request.url.path, endsWith('/rpc/get_task_details'));
        return http.Response(jsonEncode(response), 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
            request: request);
      }));
      final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => current);
      await tester.pumpWidget(MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Главная'))));
      await openGuardedPushHint(
          navigator: navigator.currentState!,
          payload: incoming,
          barrier: barrier,
          isCurrent: () => current,
          fetchSummaries: () async => [
                {'chat_id': 'chat', 'chat_type': 'team_main', 'team_id': 'team'}
              ],
          buildVerifiedTarget: (target) => buildGuardedPushQaTarget(
              incoming: incoming,
              target: target,
              client: client,
              user: 'owner',
              barrier: barrier,
              current: () => current,
              dmEnabled: false,
              teamEnabled: false,
              actionEnabled: true));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Выбор темы'), findsOneWidget);
      expect(find.text('UNTRUSTED'), findsNothing);
      expect(calls, 1);
      current = false;
      barrier.close();
      await tester.pump();
      expect(find.text('Выбор темы'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Главная'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      unawaited(client.dispose());
    });
  }
}
