import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/push/system_notification_sync.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';

void main() {
  test('only confirmed zero clears; failure and unread preserve OS alerts',
      () async {
    var clears = 0;
    for (final count in [2, 0, -1]) {
      final sync = SystemNotificationSync(
        currentUser: () => 'a',
        unreadCount: () async {
          if (count == -1) throw StateError('offline');
          return count;
        },
        clear: () async {
          clears++;
        },
      );
      await sync.reconcile();
    }
    expect(clears, 1);
  });
  test('late response cannot clear a different session', () async {
    String? user = 'a';
    var clears = 0;
    final pending = Completer<int>();
    final sync = SystemNotificationSync(
        currentUser: () => user,
        unreadCount: () => pending.future,
        clear: () async {
          clears++;
        });
    final work = sync.reconcile();
    user = 'b';
    pending.complete(0);
    await work;
    expect(clears, 0);
  });
  test('new notification invalidates pending zero response', () async {
    var clears = 0;
    final pending = Completer<int>();
    final sync = SystemNotificationSync(
        currentUser: () => 'a',
        unreadCount: () => pending.future,
        clear: () async {
          clears++;
        });
    final work = sync.reconcile();
    sync.invalidate();
    pending.complete(0);
    await work;
    expect(clears, 0);
  });
  test('closed session cannot clear after a delayed zero result', () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<int>();
    var clears = 0;
    final sync = SystemNotificationSync(currentUser: () => 'same-user',
      unreadCount: () => pending.future, clear: () async { clears++; });
    final work = barrier.run(() => sync.reconcile(isCurrent: () => barrier.isOpen));
    barrier.close();
    pending.complete(0);
    await work;
    expect(clears, 0);
  });
  test('already dispatched OS clear remains tracked until settled', () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<void>();
    final sync = SystemNotificationSync(currentUser: () => 'same-user',
      unreadCount: () async => 0, clear: () => pending.future);
    final work = barrier.run(() => sync.reconcile(isCurrent: () => barrier.isOpen));
    await Future<void>.delayed(Duration.zero);
    expect(await barrier.closeAndDrain(timeout: const Duration(milliseconds: 5)), isFalse);
    pending.complete();
    await work;
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
  });
}
