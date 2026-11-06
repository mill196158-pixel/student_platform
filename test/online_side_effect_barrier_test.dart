import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_keeper.dart';

void main() {
  test('closed barrier retains timed-out work until it settles', () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<void>();
    var calls = 0;
    final operation = barrier.run(() { calls++; return pending.future; });
    expect(barrier.activeCount, 1);
    expect(await barrier.closeAndDrain(timeout: const Duration(milliseconds: 5)), isFalse);
    expect(barrier.activeCount, 1);
    await barrier.run(() async { calls++; });
    expect(calls, 1);
    pending.complete();
    await operation;
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
  });

  test('stale owner or predicate failure permanently closes admission', () async {
    var current = true;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => current);
    current = false;
    expect(barrier.isOpen, isFalse);
    current = true;
    expect(barrier.isOpen, isFalse);
    final bad = OnlineSideEffectBarrier(ownerIsCurrent: () => throw StateError('scope'));
    expect(bad.isOpen, isFalse);
  });

  testWidgets('keeper closes the barrier on dispose while refresh drains', (tester) async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: SessionKeeper(
      barrier: barrier, refreshOverride: () { calls++; return pending.future; },
      child: const Text('home'))));
    expect(calls, 1);
    expect(barrier.activeCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(barrier.isOpen, isFalse);
    await barrier.run(() async { calls++; });
    expect(calls, 1);
    pending.complete();
    await tester.pump();
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
  });
}
