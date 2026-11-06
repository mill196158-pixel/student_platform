import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/cache_budget_policy_experiment.dart';
import 'package:student_platform/src/core/cache_reservation_arbiter_experiment.dart';

void main() {
  CacheFootprintObservation item(String id, int bytes, CacheFootprintClass kind,
      {bool inUse = false}) => CacheFootprintObservation(physicalIdentity: id,
          bytes: bytes, classification: kind, kind: CacheFootprintKind.conversation, inUse: inUse);
  CacheReservationSnapshot snapshot(List<CacheFootprintObservation> entries,
      {bool complete = true, bool Function()? current}) => CacheReservationSnapshot(
          components: entries, complete: complete, isCurrent: current ?? () => true);

  test('slow measurement holds no global lock; stale result cannot reserve', () async {
    final arbiter = CacheReservationArbiterExperiment(temporaryBudgetBytes: 100);
    final slow = Completer<CacheReservationSnapshot?>();
    final a = arbiter.reserve(peakAdditionalBytes: 50, ownerIsCurrent: () => true, measure: () => slow.future);
    final b = await arbiter.reserve(peakAdditionalBytes: 60, ownerIsCurrent: () => true,
        measure: () async => snapshot([]));
    expect(b, isNotNull);
    expect(arbiter.reservedBytes, 60);
    slow.complete(snapshot([]));
    expect(await a, isNull, reason: 'measurement predates another reservation');
    expect(b!.cancelBeforeStart(), isTrue);
    expect(b.cancelBeforeStart(), isFalse);
    expect(arbiter.reservedBytes, 0);
  });

  test('temporary budget counts peak and in-use; protected is separate from total disk', () async {
    final arbiter = CacheReservationArbiterExperiment(temporaryBudgetBytes: 100);
    Future<CacheReservationSnapshot> measure() async => snapshot([
      item('db', 20, CacheFootprintClass.temporary, inUse: true),
      item('drafts', 800, CacheFootprintClass.protected),
    ]);
    expect(await arbiter.reserve(peakAdditionalBytes: 81, ownerIsCurrent: () => true, measure: measure), isNull);
    final first = await arbiter.reserve(peakAdditionalBytes: 50, ownerIsCurrent: () => true, measure: measure);
    expect(first, isNotNull);
    expect(await arbiter.reserve(peakAdditionalBytes: 31, ownerIsCurrent: () => true, measure: measure), isNull);
    final second = await arbiter.reserve(peakAdditionalBytes: 30, ownerIsCurrent: () => true, measure: measure);
    expect(second, isNotNull);
    expect(arbiter.reservedBytes, 80);
    expect(first!.cancelBeforeStart(), isTrue);
    expect(second!.cancelBeforeStart(), isTrue);
  });

  test('started operations cannot release on cancellation, stale scope or unknown settlement', () async {
    final arbiter = CacheReservationArbiterExperiment(temporaryBudgetBytes: 100);
    var epoch = 1, settled = false, currentSnapshot = true;
    final ownerEpoch = epoch;
    final held = (await arbiter.reserve(peakAdditionalBytes: 70,
        ownerIsCurrent: () => epoch == ownerEpoch, measure: () async => snapshot([])))!;
    expect(held.start(), isTrue);
    expect(held.start(), isFalse);
    expect(held.cancelBeforeStart(), isFalse);
    expect(await held.settle(operationSettled: () => settled, measure: () async => snapshot([])), isFalse);
    settled = true;
    currentSnapshot = false;
    expect(await held.settle(operationSettled: () => settled,
        measure: () async => snapshot([], current: () => currentSnapshot)), isFalse);
    expect(arbiter.reservedBytes, 70);
    currentSnapshot = true;
    final pending = Completer<CacheReservationSnapshot?>();
    final finishing = held.settle(operationSettled: () => settled, measure: () => pending.future);
    epoch = 2;
    pending.complete(snapshot([]));
    expect(await finishing, isFalse);
    epoch = 3; // same user returning is a new epoch, not a revival
    expect(await held.settle(operationSettled: () => true, measure: () async => snapshot([])), isFalse);
    expect(arbiter.reservedBytes, 70);
  });

  test('settlement remeasures without releasing other reservations', () async {
    final arbiter = CacheReservationArbiterExperiment(temporaryBudgetBytes: 100);
    final a = (await arbiter.reserve(peakAdditionalBytes: 40, ownerIsCurrent: () => true,
        measure: () async => snapshot([])))!;
    final b = (await arbiter.reserve(peakAdditionalBytes: 30, ownerIsCurrent: () => true,
        measure: () async => snapshot([])))!;
    expect(a.start(), isTrue);
    expect(await a.settle(operationSettled: () => true,
        measure: () async => snapshot([item('final', 35, CacheFootprintClass.temporary)])), isTrue);
    expect(arbiter.reservedBytes, 30);
    expect(await a.settle(operationSettled: () => true, measure: () async => snapshot([])), isFalse);
    expect(await arbiter.reserve(peakAdditionalBytes: 36, ownerIsCurrent: () => true,
        measure: () async => snapshot([item('final', 35, CacheFootprintClass.temporary)])), isNull);
    expect(b.cancelBeforeStart(), isTrue);
  });

  test('mixed, duplicate, incomplete, stale and throwing collectors fail closed', () async {
    final arbiter = CacheReservationArbiterExperiment(temporaryBudgetBytes: 100);
    Future<CacheReservationExperiment?> trySnapshot(CacheReservationSnapshot value) =>
        arbiter.reserve(peakAdditionalBytes: 1, ownerIsCurrent: () => true, measure: () async => value);
    expect(await trySnapshot(snapshot([item('db', 1, CacheFootprintClass.mixed)])), isNull);
    expect(await trySnapshot(snapshot([item('db', 1, CacheFootprintClass.temporary),
      item('db', 1, CacheFootprintClass.protected)])), isNull);
    expect(await trySnapshot(snapshot([], complete: false)), isNull);
    expect(await trySnapshot(snapshot([], current: () => false)), isNull);
    expect(await arbiter.reserve(peakAdditionalBytes: 1, ownerIsCurrent: () => true,
        measure: () async => throw StateError('unknown')), isNull);
    expect(arbiter.reservedBytes, 0);
  });

  test('measurement invalidated after reservation cannot start', () async {
    final arbiter = CacheReservationArbiterExperiment(temporaryBudgetBytes: 100);
    var current = true;
    final reservation = (await arbiter.reserve(peakAdditionalBytes: 30, ownerIsCurrent: () => true,
        measure: () async => snapshot([], current: () => current)))!;
    current = false;
    expect(reservation.start(), isFalse);
    expect(arbiter.reservedBytes, 30);
    expect(reservation.cancelBeforeStart(), isTrue);
    expect(arbiter.reservedBytes, 0);
  });
}
