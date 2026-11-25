import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/ui/notifications/push_session_host.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/system_notification_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('guarded notification changes reconcile the launcher count',
      (tester) async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final firstCount = Completer<int>();
    var queries = 0, clears = 0, count = 1;
    late void Function(PostgresChangePayload) handle;
    PostgresChangePayload event(PostgresChangeEvent type,
            {String user = 'owner'}) =>
        PostgresChangePayload(
            schema: 'public',
            table: 'app_notifications',
            commitTimestamp: DateTime(2026),
            eventType: type,
            newRecord: {
              'id': 'notification',
              'recipient_id': user,
              'event_type': 'announcement',
              if (type == PostgresChangeEvent.update) 'read_at': '2026-11-25',
            },
            oldRecord: const {},
            errors: null);
    await tester.pumpWidget(MaterialApp(
        home: PushSessionHost(
            barrier: barrier,
            debugCurrentUser: () => 'owner',
            debugAuthenticated: () async {},
            debugFlush: () async {},
            debugSubscribe: (callback) => handle = callback,
            debugSystemNotifications: SystemNotificationSync(
              currentUser: () => 'owner',
              lookupRead: (owner, ids) async => {},
              listDelivered: () async => [(tag: 'FCM-Notification:123', id: 0)],
              unreadCount: () async {
              queries++;
              return queries == 1 ? firstCount.future : count;
            }, cancelDelivered: (_) async { clears++; }),
            child: const Text('home'))));
    expect(queries, 1);

    handle(event(PostgresChangeEvent.insert));
    firstCount.complete(0);
    await tester.pump();
    expect(clears, 0);

    handle(event(PostgresChangeEvent.update));
    handle(event(PostgresChangeEvent.update));
    await tester.pump(const Duration(milliseconds: 100));
    expect(queries, 2);
    expect(clears, 0);

    count = 0;
    handle(event(PostgresChangeEvent.update, user: 'different'));
    handle(PostgresChangePayload(
        schema: 'public',
        table: 'app_notifications',
        commitTimestamp: DateTime(2026),
        eventType: PostgresChangeEvent.delete,
        newRecord: const {},
        oldRecord: const {'id': 'other'},
        errors: null));
    await tester.pump(const Duration(milliseconds: 100));
    expect(queries, 2);
    handle(event(PostgresChangeEvent.update));
    await tester.pump(const Duration(milliseconds: 100));
    expect(clears, 1);

    handle(event(PostgresChangeEvent.update));
    barrier.close();
    await tester.pump(const Duration(milliseconds: 100));
    expect(queries, 3);
  });

  testWidgets('push start remains tracked across disposal and blocks new dispatch', (tester) async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<void>();
    var starts = 0, reconciles = 0;
    await tester.pumpWidget(MaterialApp(home: PushSessionHost(
      barrier: barrier,
      debugStart: () { starts++; return pending.future; },
      debugReconcile: () async { reconciles++; },
      child: const Text('home'))));
    await tester.pump();
    expect(starts, 1);
    expect(reconciles, 1);
    expect(barrier.activeCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(barrier.isOpen, isFalse);
    await barrier.run(() async { starts++; });
    expect(starts, 1);
    pending.complete();
    await tester.pump();
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
  });

  testWidgets('closed barrier prevents push start and reconciliation', (tester) async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true)..close();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: PushSessionHost(
      barrier: barrier,
      debugStart: () async { calls++; },
      debugReconcile: () async { calls++; },
      child: const Text('home'))));
    await tester.pump();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old start cannot flush navigation after barrier replacement', (tester) async {
    final first = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final second = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<void>();
    final pendingSecond = Completer<void>();
    var oldFlushes = 0, newFlushes = 0;
    Widget host(OnlineSideEffectBarrier barrier) => MaterialApp(
      home: PushSessionHost(key: const ValueKey('push'), barrier: barrier,
        debugCurrentUser: () => 'a', debugReconcile: () async {},
        debugAuthenticated: () => identical(barrier, first) ? pending.future : pendingSecond.future,
        debugFlush: () async { if (identical(barrier, first)) { oldFlushes++; } else { newFlushes++; } },
        child: const Text('home')));
    await tester.pumpWidget(host(first));
    await tester.pump();
    expect(first.activeCount, 1);
    await tester.pumpWidget(host(second));
    expect(first.isOpen, isFalse);
    pending.complete();
    await tester.pump();
    expect(oldFlushes, 0);
    expect(await first.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
    pendingSecond.complete();
    await tester.pump();
    expect(newFlushes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old realtime callback cannot publish after same-user barrier replacement', (tester) async {
    final first = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final second = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final callbacks = <void Function(PostgresChangePayload)>[];
    final events = <InAppNotificationEvent>[];
    final subscription = InAppNotificationBus.instance.stream.listen(events.add);
    Widget host(OnlineSideEffectBarrier barrier) => MaterialApp(
      home: PushSessionHost(key: const ValueKey('push'), barrier: barrier,
        debugCurrentUser: () => 'same-user', debugReconcile: () async {},
        debugAuthenticated: () async {}, debugFlush: () async {},
        debugSubscribe: callbacks.add, child: const Text('home')));
    await tester.pumpWidget(host(first));
    await tester.pump();
    expect(callbacks, hasLength(1));
    await tester.pumpWidget(host(second));
    await tester.pump();
    expect(callbacks, hasLength(2));
    final payload = PostgresChangePayload(schema: 'public', table: 'app_notifications',
      commitTimestamp: DateTime(2026), eventType: PostgresChangeEvent.insert,
      newRecord: {'id': 'n', 'recipient_id': 'same-user', 'event_type': 'announcement', 'title': 'QA', 'body': 'test'},
      oldRecord: const {}, errors: null);
    callbacks.first(payload);
    await tester.pump();
    expect(events.where((e) => e.title == 'QA'), isEmpty);
    callbacks.last(payload);
    await tester.pump();
    expect(events.where((e) => e.title == 'QA'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(subscription.cancel());
    await tester.pump();
  });
}
