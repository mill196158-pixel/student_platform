import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/guarded_push_open.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';

void main() {
  test('verified owner opens, unverified payload does not', () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    var opened = 0;
    Future<void> attempt(bool verified) => openVerifiedPush(
        barrier: barrier,
        isCurrent: () => true,
        verify: () async => verified,
        open: () async {
          opened++;
        });
    await attempt(false);
    await attempt(true);
    expect(opened, 1);
  });
  test('late verification from owner A cannot open in B', () async {
    var current = true;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => current);
    final verify = Completer<bool>();
    var opened = 0;
    final work = openVerifiedPush(
        barrier: barrier,
        isCurrent: () => current,
        verify: () => verify.future,
        open: () async {
          opened++;
        });
    current = false;
    barrier.close();
    verify.complete(true);
    await work;
    expect(opened, 0);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)),
        isTrue);
  });
  testWidgets('navigation dispatch settles while pushed page remains open',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Text('home')));
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final work = openVerifiedPush(
        barrier: barrier,
        isCurrent: () => true,
        verify: () async => true,
        open: () => PushNavigation.debugPushGuarded(
            navigator.currentState!,
            MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('opened'))),
            barrier));
    await tester.pumpAndSettle();
    await work;
    expect(find.text('opened'), findsOneWidget);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)),
        isTrue);
    await tester.pumpAndSettle();
    expect(find.text('opened'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
