import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, temp, db, support;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('typed_budget_');
    temp = await Directory('${root.path}/temp').create();
    db = await Directory('${root.path}/db').create();
    support = await Directory('${root.path}/support').create();
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  CacheInventoryCollector collector(
          {Duration Function()? elapsed,
          Future<Directory> Function()? tempRoot}) =>
      CacheInventoryCollector(
          temporaryRoot: tempRoot ?? () async => temp,
          databaseRoot: () async => db,
          supportRoot: () async => support,
          elapsed: elapsed,
          logicalHistory: () async => 999999999);
  Future<void> seed() async {
    for (final name in [
      'public_news_blobs_v2',
      'news_images_v1',
      'guest_news_images_v1',
      'content_media_images_v1'
    ]) {
      final folder = await Directory('${temp.path}/$name').create();
      await File('${folder.path}/one').writeAsBytes([1, 2, 3]);
    }
    await File('${db.path}/public_news_index_v2.db').writeAsBytes([1, 2]);
    await File('${db.path}/offline_chat_ordinary_v1.db')
        .writeAsBytes(List.filled(100, 1));
  }

  test(
      'typed four image roots and index counted, protected/logical excluded, reservations compete',
      () async {
    await seed();
    final budget = OptionalImageCacheBudget(
        collector: collector(), limitBytes: 20, serviceReserveBytes: 2);
    await budget.refreshForTesting();
    expect(budget.observedBytes, 14);
    expect(budget.reserve(0x7fffffffffffffff), isNull);
    final release = budget.reserve(3);
    expect(release, isNotNull);
    expect(budget.reserve(2), isNull);
    release!();
    expect(budget.reserve(2), isNull);
    expect(await File('${db.path}/offline_chat_ordinary_v1.db').length(), 100);
  });
  test('invalid limits and service reserves are rejected', () {
    expect(() => OptionalImageCacheBudget(limitBytes: -1), throwsArgumentError);
    expect(() => OptionalImageCacheBudget(serviceReserveBytes: -1),
        throwsArgumentError);
  });
  test('oversized typed observation cannot wrap into an allowed budget',
      () async {
    final items = [
      const InventoryObservation(
          'public_news_blobs_v2', InventoryClass.optional, 0x7fffffffffffffff),
      for (final name in [
        'public_news_index_v2.db',
        'news_images_v1',
        'guest_news_images_v1',
        'content_media_images_v1'
      ])
        InventoryObservation(name, InventoryClass.serverCopiesUnverified, 1),
    ];
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: items);
    final budget = OptionalImageCacheBudget(
        collector: _FakeCollector(snapshot), serviceReserveBytes: 0);
    await budget.refreshForTesting();
    expect(budget.observedBytes, isNull);
    expect(budget.reserve(1), isNull);
  });
  test('unknown optional source denies admission', () async {
    final missing = Directory('${root.path}/missing');
    final budget = OptionalImageCacheBudget(
        collector: collector(tempRoot: () async => missing),
        serviceReserveBytes: 0);
    await budget.refreshForTesting();
    expect(budget.observedBytes, isNull);
    expect(budget.reserve(1), isNull);
  });
  test('joining an older settings scan never makes it fresh', () async {
    var now = Duration.zero;
    final gate = Completer<Directory>();
    final c = collector(elapsed: () => now, tempRoot: () => gate.future);
    final settingsScan = c.collect();
    now = const Duration(seconds: 2);
    final budget = OptionalImageCacheBudget(
        collector: c,
        elapsed: () => now,
        refreshInterval: const Duration(seconds: 1),
        serviceReserveBytes: 0);
    final budgetScan = budget.refreshForTesting();
    gate.complete(temp);
    await settingsScan;
    await budgetScan;
    expect(budget.observedBytes, isNull);
    expect(budget.reserve(1), isNull);
  });
  testWidgets('settings displays the same real budget measurement',
      (tester) async {
    late InventorySnapshot snapshot;
    late OptionalImageCacheBudget budget;
    await tester.runAsync(() async {
      await seed();
      final c = collector();
      budget = OptionalImageCacheBudget(collector: c, serviceReserveBytes: 0);
      await budget.refreshForTesting();
      snapshot = await c.collect();
    });
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            measure: () async => snapshot, budget: budget)));
    await tester.pump();
    expect(find.text('Учтённые копии новостей и материалов: 0.0 МБ'),
        findsOneWidget);
    expect(budget.observedBytes, 14);
    expect(find.textContaining('часть подтверждённой истории чатов'),
        findsOneWidget);
  });
}

class _FakeCollector extends CacheInventoryCollector {
  _FakeCollector(this.snapshot)
      : super(
            temporaryRoot: () async => Directory('.'),
            databaseRoot: () async => Directory('.'),
            supportRoot: () async => Directory('.'));
  final InventorySnapshot snapshot;
  @override
  Future<InventorySnapshot> collect() async => snapshot;
  @override
  Duration? ageOf(InventorySnapshot snapshot) => Duration.zero;
}
