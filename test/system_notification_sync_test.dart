import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/system_notification_sync.dart';

const owner = '00000000-0000-4000-8000-000000000001';
const otherOwner = '00000000-0000-4000-8000-000000000002';
const first = '00000000-0000-4000-8000-000000000003';
const second = '00000000-0000-4000-8000-000000000004';
const read = (tag: 'student:$owner:$first', id: 0);
const unread = (tag: 'student:$owner:$second', id: 0);
const foreign = (tag: 'student:$otherOwner:$first', id: 0);
const legacy = (tag: 'FCM-Notification:123', id: 0);
const unrelated = (tag: 'alarm', id: 0);

void main() {
  late List<DeliveredNotification> drawer;
  late String user;
  late Future<int> Function() count;
  late Future<Set<String>> Function(String, Set<String>) lookup;
  late SystemNotificationSync sync;
  final removed = <DeliveredNotification>[];
  setUp(() {
    drawer = [read, unread, foreign, legacy, unrelated];
    removed.clear();
    user = owner;
    count = () async => 1;
    lookup = (ownerId, ids) async {
      expect(ownerId, owner);
      expect(ids, {first, second});
      return {first};
    };
    sync = SystemNotificationSync(
        currentUser: () => user,
        unreadCount: () => count(),
        lookupRead: (owner, ids) => lookup(owner, ids),
        listDelivered: () async => [...drawer],
        cancelDelivered: (alerts) async => removed.addAll(alerts));
  });

  test('only the confirmed read row is cancelled while another is unread',
      () async {
    await sync.reconcile();
    expect(removed, [read]);
  });

  test(
      'zero removes only current snapshot FCM alerts, keeping other accounts and new arrivals',
      () async {
    count = () async {
      drawer.add(
          (tag: 'student:$owner:00000000-0000-4000-8000-000000000005', id: 0));
      return 0;
    };
    await sync.reconcile();
    expect(removed, unorderedEquals([read, unread, legacy]));
  });

  test('unknown, malformed, absent, or failed read proofs preserve the drawer',
      () async {
    lookup = (owner, ids) async => {};
    await sync.reconcile();
    lookup = (owner, ids) async => {otherOwner};
    await sync.reconcile();
    lookup = (owner, ids) async => throw const FormatException();
    await sync.reconcile();
    count = () async => throw StateError('offline');
    await sync.reconcile();
    expect(removed, isEmpty);
  });

  test('late zero cannot clear a different session', () async {
    count = () async {
      user = otherOwner;
      return 0;
    };
    await sync.reconcile();
    expect(removed, isEmpty);
  });

  test('new event invalidates a pending read lookup', () async {
    lookup = (owner, ids) async {
      sync.invalidate();
      return {first};
    };
    await sync.reconcile();
    expect(removed, isEmpty);
  });

  test('barrier closure blocks a pending lookup for the same user', () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    lookup = (owner, ids) async {
      barrier.close();
      return {first};
    };
    await barrier.run(() => sync.reconcile(isCurrent: () => barrier.isOpen));
    expect(removed, isEmpty);
  });

  test(
      'acknowledged concurrent reads are both applied regardless of other arrivals',
      () async {
    final firstRead = sync.dismissRead(owner, {first}, isCurrent: () => true);
    sync.invalidate();
    final secondRead = sync.dismissRead(owner, {second}, isCurrent: () => true);
    await Future.wait([firstRead, secondRead]);
    expect(removed, unorderedEquals([read, unread]));
    await sync.dismissRead(otherOwner, {first}, isCurrent: () => true);
    await sync.dismissRead(owner, {first}, isCurrent: () => false);
    expect(removed.length, 2);
  });

  test('already dispatched OS removal remains tracked until settled', () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<void>();
    sync = SystemNotificationSync(
        currentUser: () => owner,
        unreadCount: () async => 0,
        lookupRead: (owner, ids) async => {},
        listDelivered: () async => [read],
        cancelDelivered: (_) => pending.future);
    final work =
        barrier.run(() => sync.reconcile(isCurrent: () => barrier.isOpen));
    await Future<void>.delayed(Duration.zero);
    expect(
        await barrier.closeAndDrain(timeout: const Duration(milliseconds: 5)),
        isFalse);
    pending.complete();
    await work;
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)),
        isTrue);
  });
}
