import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/guarded_push_hint.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';

void main() {
  if (!const bool.fromEnvironment('GUARDED_PUSH_HINT_QA')) {
    test('neutral hint is disabled in the default build', () {
      expect(debugGuardedPushHintQaEnabled, isFalse);
    });
  } else {
    test('neutral hint is enabled only with its explicit QA flag', () {
      expect(debugGuardedPushHintQaEnabled, isTrue);
    });
  }
  const payload = PushPayload(
      version: 1,
      type: 'dm_message',
      chatId: 'chat',
      peerId: 'untrusted-peer',
      raw: {'title': 'old private title'});
  final row = {'chat_id': 'chat', 'chat_type': 'dm', 'peer_id': 'server-peer'};

  testWidgets('verified no-ID hint is neutral and closes on barrier revoke',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const Scaffold(body: Text('home'))));
    var owner = true, requests = 0;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => owner);
    await openGuardedPushHint(
        navigator: navigator.currentState!,
        payload: payload,
        barrier: barrier,
        isCurrent: () => owner,
        fetchSummaries: () async {
          requests++;
          return [row];
        });
    await tester.pumpAndSettle();
    expect(find.textContaining('Чтобы открыть чат'), findsOneWidget);
    expect(find.textContaining('old private title'), findsNothing);
    expect(find.textContaining('server-peer'), findsNothing);
    expect(requests, 1);
    owner = false;
    barrier.close();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('Чтобы открыть чат'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('missing, duplicate, malformed and rejected lookups do not open',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const Scaffold(body: Text('home'))));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    for (final value in [
      <Object>[],
      [row, row],
      [row, 'invalid'],
      [{'chat_id': 'chat', 'chat_type': 'dm', 'peer_id': 'server-peer', 'hidden_at': '2026-01-01'}],
      'invalid'
    ]) {
      await openGuardedPushHint(
          navigator: navigator.currentState!,
          payload: payload,
          barrier: barrier,
          isCurrent: () => true,
          fetchSummaries: () async => value);
    }
    await openGuardedPushHint(
        navigator: navigator.currentState!,
        payload: payload,
        barrier: barrier,
        isCurrent: () => true,
        fetchSummaries: () async => throw StateError('synthetic denial'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Чтобы открыть чат'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('late response and owner ABA cannot open or escape drain',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const Scaffold(body: Text('home'))));
    var generation = 1;
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => generation == 1);
    final response = Completer<dynamic>();
    final work = openGuardedPushHint(
        navigator: navigator.currentState!,
        payload: payload,
        barrier: barrier,
        isCurrent: () => generation == 1,
        fetchSummaries: () => response.future);
    generation = 2;
    barrier.close();
    final drain = barrier.closeAndDrain(timeout: const Duration(seconds: 1));
    expect(barrier.activeCount, 1);
    generation = 3; // Same user later, distinct session generation.
    response.complete([row]);
    await work;
    expect(await drain, isTrue);
    await tester.pumpAndSettle();
    expect(find.textContaining('Чтобы открыть чат'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
