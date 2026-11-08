import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('observation_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
      'fresh observation is reusable; issuer, reservations and expiry fence it',
      () async {
    var now = Duration.zero;
    final budget = OptionalImageCacheBudget(
        roots: () async => [root],
        elapsed: () => now,
        refreshInterval: const Duration(seconds: 1),
        limitBytes: 100);
    final other =
        OptionalImageCacheBudget(roots: () async => [root], limitBytes: 100);
    await budget.refreshForTesting();
    final token = budget.captureFreshObservation()!;
    expect(token.observedBytes, 0);
    expect(token.reservedBytes, 0);
    expect(token.limitBytes, 100);
    expect(token.serviceReserveBytes, 0);
    expect(budget.isObservationCurrent(token), isTrue);
    expect(budget.isObservationCurrent(token), isTrue);
    expect(other.isObservationCurrent(token), isFalse);
    final release = budget.reserve(4)!;
    expect(budget.isObservationCurrent(token), isFalse);
    final during = budget.captureFreshObservation()!;
    expect(during.reservedBytes, 4);
    release();
    expect(budget.isObservationCurrent(during), isFalse);
    final after = budget.captureFreshObservation()!;
    expect(after.observedBytes, 4);
    now = const Duration(seconds: 1);
    expect(budget.isObservationCurrent(after), isFalse);
    expect(budget.captureFreshObservation(), isNull);
  });

  test(
      'refresh starts invalidate, pending cannot capture, completion creates fresh revision',
      () async {
    final pending = Completer<List<Directory>>();
    var scans = 0;
    final budget = OptionalImageCacheBudget(
        roots: () => ++scans == 1 ? Future.value([root]) : pending.future,
        limitBytes: 100);
    await budget.refreshForTesting();
    final before = budget.captureFreshObservation()!;
    budget.refreshAfterCollection();
    expect(budget.isObservationCurrent(before), isFalse);
    expect(budget.captureFreshObservation(), isNull);
    pending.complete([root]);
    await budget.refreshForTesting();
    final after = budget.captureFreshObservation()!;
    expect(budget.isObservationCurrent(before), isFalse);
    expect(budget.isObservationCurrent(after), isTrue);
    expect(scans, 2);
  });

  test('unknown scan never yields a token', () async {
    final budget = OptionalImageCacheBudget(
        roots: () async => [Directory('${root.path}/missing')]);
    await budget.refreshForTesting();
    expect(budget.captureFreshObservation(), isNull);
  });
}
