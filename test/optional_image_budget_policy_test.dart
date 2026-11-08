import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('budget_policy_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  test('defaults, persists and reloads an applied choice', () async {
    final b = OptionalImageCacheBudget(
        roots: () async => [root], persistPolicy: true);
    await b.waitForPolicy();
    expect(b.policyReady, isTrue);
    expect(b.limitBytes, 500000000);
    expect(await b.setLimit(250000000), isTrue);
    await b.waitForPolicy();
    expect(b.limitBytes, 250000000);
    final next = OptionalImageCacheBudget(
        roots: () async => [root], persistPolicy: true);
    await next.waitForPolicy();
    expect(next.limitBytes, 250000000);
  });
  test('corrupt policy stays unavailable and explicit valid choice recovers',
      () async {
    SharedPreferences.setMockInitialValues(
        {OptionalImageCacheBudget.policyKey: 'bad'});
    final b = OptionalImageCacheBudget(
        roots: () async => [root], persistPolicy: true);
    await b.waitForPolicy();
    await b.refreshForTesting();
    expect(b.policyReady, isFalse);
    expect(b.reserve(1), isNull);
    expect(await b.setLimit(1000000000), isTrue);
    await b.waitForPolicy();
    expect(b.policyReady, isTrue);
    expect(b.limitBytes, 1000000000);
  });
  test('failed write refuses admission and successful explicit retry recovers',
      () async {
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final b = OptionalImageCacheBudget(
        roots: () async => [root],
        persistPolicy: true,
        preferences: () async {
          calls++;
          if (calls == 2) throw StateError('unavailable');
          return prefs;
        });
    await b.waitForPolicy();
    await b.refreshForTesting();
    final old = b.captureFreshObservation()!;
    final change = b.setLimit(250000000);
    expect(b.isObservationCurrent(old), isFalse);
    expect(b.reserve(1), isNull);
    expect(await change, isFalse);
    await b.waitForPolicy();
    expect(b.policyReady, isFalse);
    expect(await b.setLimit(1000000000), isTrue);
    await b.waitForPolicy();
    expect(b.policyReady, isTrue);
    expect(b.limitBytes, 1000000000);
  });

  test(
      'false platform write leaves admission unavailable despite mutated prefs cache',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final budget = OptionalImageCacheBudget(
        roots: () async => [root],
        persistPolicy: true,
        preferences: () async => prefs);
    await budget.waitForPolicy();
    await budget.refreshForTesting();
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _FalseWriteStore();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previous;
    });
    expect(await budget.setLimit(250000000), isFalse);
    await budget.waitForPolicy();
    expect(prefs.getInt(OptionalImageCacheBudget.policyKey), 250000000);
    expect(budget.policyReady, isFalse);
    expect(budget.reserve(1), isNull);
  });
  test('FIFO choices and active reservation settle without losing charge',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final gated = Completer<SharedPreferences>();
    var calls = 0;
    final b = OptionalImageCacheBudget(
        roots: () async => [root],
        persistPolicy: true,
        preferences: () {
          calls++;
          return calls == 2 ? gated.future : Future.value(prefs);
        });
    await b.waitForPolicy();
    await b.refreshForTesting();
    final release = b.reserve(4)!;
    final one = b.setLimit(250000000), two = b.setLimit(1000000000);
    expect(b.reserve(1), isNull);
    release();
    gated.complete(prefs);
    expect(await one, isTrue);
    expect(await two, isTrue);
    await b.waitForPolicy();
    expect(b.limitBytes, 1000000000);
    expect(b.observedBytes, 4);
  });

  test('lowering limit preserves active write and blocks new reservations',
      () async {
    final observations = [
      const InventoryObservation(
          'public_news_blobs_v2', InventoryClass.optional, 249999999),
      for (final name in [
        'public_news_index_v2.db',
        'news_images_v1',
        'guest_news_images_v1',
        'content_media_images_v1'
      ])
        InventoryObservation(name, InventoryClass.serverCopiesUnverified, 0),
    ];
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: observations);
    final b = OptionalImageCacheBudget(
        collector: _FixedCollector(snapshot),
        persistPolicy: true,
        serviceReserveBytes: 0);
    await b.waitForPolicy();
    await b.refreshForTesting();
    final held = b.reserve(4)!;
    expect(await b.setLimit(250000000), isTrue);
    await b.waitForPolicy();
    expect(b.reserve(1), isNull);
    held();
    expect(b.observedBytes, 250000003);
    expect(b.reserve(1), isNull);
  });
  test('first real image write retries after delayed initial policy and scan',
      () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    final b = OptionalImageCacheBudget(
        roots: () async => [root],
        persistPolicy: true,
        preferences: () => gate.future);
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(
        rootOverride: () => cacheRoot, memory: memory, debugOptionalBudget: b);
    final key = NewsImageCacheKey(path: 'news/pending', version: '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    await disk.put(key, bytes);
    expect(await disk.peek(key), bytes);
    gate.complete(prefs);
    for (var i = 0;
        i < 100 && !await File('${cacheRoot.path}/index.json').exists();
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    memory.clear();
    expect(await disk.peek(key), bytes);
  });

  testWidgets('settings applies chosen limit to the same admission budget',
      (tester) async {
    late OptionalImageCacheBudget b;
    await tester.runAsync(() async {
      b = OptionalImageCacheBudget(
          roots: () async => [root], persistPolicy: true);
      await b.waitForPolicy();
      await b.refreshForTesting();
    });
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []);
    await tester.pumpWidget(MaterialApp(
        home:
            CacheDiagnosticsScreen(measure: () async => snapshot, budget: b)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить лимит копий'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('250 МБ'));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    for (var i = 0; i < 20 && b.policyBusy; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(b.limitBytes, 250000000);
    expect(
        find.textContaining('Лимит для этих копий — 250.0 МБ'), findsOneWidget);
  });
}

class _FalseWriteStore extends InMemorySharedPreferencesStore {
  _FalseWriteStore() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

class _FixedCollector extends CacheInventoryCollector {
  _FixedCollector(this.snapshot)
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
