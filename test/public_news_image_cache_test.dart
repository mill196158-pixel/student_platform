import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _GatedLegacy extends NewsImageDiskCache {
  final entered = Completer<void>();
  final release = Completer<Uint8List?>();
  @override
  Future<Uint8List?> peekLegacyReadOnly(NewsImageCacheKey key) { entered.complete(); return release.future; }
}

class _CountingBudget extends OptionalImageCacheBudget {
  _CountingBudget({required super.roots});
  int calls = 0;
  @override
  void Function()? reserve(int bytes) { calls++; return super.reserve(bytes); }
}

class _CountingStore extends NewsSqliteImageStore {
  _CountingStore({required super.database, required super.root});
  int calls = 0;
  final written = Completer<void>();
  @override
  Future<bool> put(NewsImageCacheKey key, Uint8List bytes, NewsImageWriteTicket ticket) async {
    calls++;
    if (!written.isCompleted) written.complete();
    return true;
  }
}

class _ServiceMount extends StatefulWidget {
  const _ServiceMount({required this.create, required this.observed});
  final HomeDashboardService Function() create;
  final List<PublicNewsImageCache> observed;
  @override
  State<_ServiceMount> createState() => _ServiceMountState();
}

class _ServiceMountState extends State<_ServiceMount> {
  late final HomeDashboardService service;
  @override
  void initState() {
    super.initState();
    service = widget.create();
    widget.observed.add(service.debugPublicImageCache);
  }
  @override
  void dispose() { service.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late Database dbA, dbB;
  late NewsSqliteImageStore storeA, storeB;
  late NewsImageDiskCache legacy;
  late OptionalImageCacheBudget budget;
  late PublicNewsImageCache a, b;
  final key = NewsImageCacheKey(path: 'public/news', version: '1');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('public-news-');
    dbA = await databaseFactoryFfi.openDatabase('${root.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    dbB = await databaseFactoryFfi.openDatabase('${root.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    storeA = NewsSqliteImageStore(database: dbA, root: Directory('${root.path}/blobs'));
    storeB = NewsSqliteImageStore(database: dbB, root: Directory('${root.path}/blobs'));
    legacy = NewsImageDiskCache(rootOverride: () => Directory('${root.path}/legacy'), memory: NewsImageBytesCache());
    budget = OptionalImageCacheBudget(roots: () async => [root]);
    await budget.refreshForTesting();
    a = PublicNewsImageCache(legacy: legacy, openStore: () async => storeA, budget: budget);
    b = PublicNewsImageCache(legacy: legacy, openStore: () async => storeB, budget: budget);
  });
  tearDown(() async { await dbA.close(); await dbB.close(); await root.delete(recursive: true); });

  test('other instance clear suppresses legacy and preloaded bytes', () async {
    await legacy.put(key, Uint8List.fromList([1]));
    expect((await a.read(key)).bytes, [1]);
    await b.invalidate();
    var fallbackCalls = 0;
    final result = await a.read(key, legacyFallback: () async { fallbackCalls++; return Uint8List.fromList([2]); });
    expect(result.state, NewsImageReadState.miss);
    expect(fallbackCalls, 0);
  });

  test('8 MiB image is admitted for optional persistence', () async {
    final spy = _CountingStore(database: dbA, root: Directory('${root.path}/blobs'));
    final counting = _CountingBudget(roots: () async => [root]);
    await counting.refreshForTesting();
    final cache = PublicNewsImageCache(legacy: legacy, openStore: () async => spy, budget: counting);
    final bytes = Uint8List(PublicNewsImageCache.maxOptionalImageBytes);
    expect(await cache.getOrFetch(key, () async => bytes), same(bytes));
    await spy.written.future.timeout(const Duration(seconds: 2));
    expect(counting.calls, 1);
    expect(spy.calls, 1);
  });

  for (final pendingScan in [false, true]) {
    test('oversized image bypasses optional write with ${pendingScan ? 'pending' : 'ready'} scan', () async {
      final roots = Completer<List<Directory>>();
      if (!pendingScan) roots.complete([root]);
      final counting = _CountingBudget(roots: () => roots.future);
      final scan = counting.refreshForTesting();
      if (!pendingScan) await scan;
      final spy = _CountingStore(database: dbA, root: Directory('${root.path}/blobs'));
      final cache = PublicNewsImageCache(legacy: legacy, openStore: () async => spy, budget: counting);
      final bytes = Uint8List(PublicNewsImageCache.maxOptionalImageBytes + 1);
      expect(await cache.getOrFetch(key, () async => bytes), same(bytes));
      expect(counting.calls, 0);
      expect(spy.calls, 0);
      if (pendingScan) { roots.complete([root]); await scan; }
    });
  }

  test('oversized download completing after invalidation is not displayed or written', () async {
    final spy = _CountingStore(database: dbA, root: Directory('${root.path}/blobs'));
    final counting = _CountingBudget(roots: () async => [root]);
    await counting.refreshForTesting();
    final cache = PublicNewsImageCache(legacy: legacy, openStore: () async => spy, budget: counting);
    final entered = Completer<void>(), response = Completer<Uint8List?>();
    final pending = cache.getOrFetch(key, () { entered.complete(); return response.future; });
    await entered.future;
    await b.invalidate(key.path);
    response.complete(Uint8List(PublicNewsImageCache.maxOptionalImageBytes + 1));
    expect(await pending, isNull);
    expect(counting.calls, 0);
    expect(spy.calls, 0);
  });

  test('default services share one app-lifetime news coordinator', () async {
    final httpClient = MockClient((_) async => http.Response('', 503));
    final client = SupabaseClient('https://example.invalid', 'synthetic', httpClient: httpClient);
    HomeDashboardService service() => HomeDashboardService(client: client,
        scheduleRepository: ScheduleRepository(client: client),
        learningRepository: SupabaseLearningRepository(client: client), httpClient: httpClient);
    final first = service(), second = service();
    expect(identical(first.debugPublicImageCache, second.debugPublicImageCache), isTrue);
    expect(identical(first.debugPublicImageCache, PublicNewsImageCache.shared), isTrue);
    first.dispose(); second.dispose(); await client.dispose();
  });

  testWidgets('repeated widget mounts reuse the default coordinator', (tester) async {
    final httpClient = MockClient((_) async => http.Response('', 503));
    final client = SupabaseClient('https://example.invalid', 'synthetic', httpClient: httpClient,
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    HomeDashboardService create() => HomeDashboardService(client: client,
        scheduleRepository: ScheduleRepository(client: client),
        learningRepository: SupabaseLearningRepository(client: client), httpClient: httpClient);
    final observed = <PublicNewsImageCache>[];
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(_ServiceMount(create: create, observed: observed));
      await tester.pumpWidget(const SizedBox());
    }
    expect(observed, hasLength(5));
    expect(observed.every((item) => identical(item, PublicNewsImageCache.shared)), isTrue);
    unawaited(client.dispose());
  });

  test('disposing one service does not close supplied shared cache or cancel fetch', () async {
    final httpClient = MockClient((_) async => http.Response('', 503));
    final client = SupabaseClient('https://example.invalid', 'synthetic', httpClient: httpClient);
    HomeDashboardService service() => HomeDashboardService(client: client,
        scheduleRepository: ScheduleRepository(client: client),
        learningRepository: SupabaseLearningRepository(client: client),
        publicImageCache: a, httpClient: httpClient);
    final first = service(), second = service();
    final started = Completer<void>(), response = Completer<Uint8List?>();
    final pending = a.getOrFetch(key, () { started.complete(); return response.future; });
    await started.future;
    first.dispose();
    response.complete(Uint8List.fromList([2]));
    expect(await pending, [2]);
    expect(dbA.isOpen, isTrue);
    expect(identical(second.debugPublicImageCache, a), isTrue);
    second.dispose(); await client.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('same-instance invalidation fences an already running legacy read', () async {
    final gated = _GatedLegacy();
    final cache = PublicNewsImageCache(legacy: gated, openStore: () async => storeA, budget: budget);
    final old = cache.read(key);
    await gated.entered.future;
    final invalidating = cache.invalidate(key.path);
    gated.release.complete(Uint8List.fromList([1]));
    expect((await old).state, NewsImageReadState.unknown);
    await invalidating;
  });

  test('hung DB read times out to fresh network and cannot publish late bytes', () async {
    final gated = _GatedLegacy();
    final cache = PublicNewsImageCache(legacy: gated, openStore: () async => storeA,
        budget: budget, operationTimeout: const Duration(milliseconds: 40));
    var downloads = 0;
    final result = cache.getOrFetch(key, () async { downloads++; return Uint8List.fromList([7]); });
    await gated.entered.future;
    expect(await result.timeout(const Duration(seconds: 2)), [7]);
    expect(downloads, 1);
    gated.release.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await storeA.read(key), anyOf(isNull, equals([7])));
  });

  test('hung legacy read releases transaction so clear completes and late data stays hidden', () async {
    final gated = _GatedLegacy();
    final cache = PublicNewsImageCache(legacy: gated, openStore: () async => storeA,
        budget: budget, operationTimeout: const Duration(milliseconds: 80));
    final pending = cache.read(key);
    await gated.entered.future;
    final clear = b.invalidate(key.path);
    expect((await pending.timeout(const Duration(seconds: 2))).state, NewsImageReadState.unknown);
    await clear.timeout(const Duration(seconds: 2));
    gated.release.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect((await cache.read(key)).state, NewsImageReadState.miss);
  });

  test('unknown DB never uses legacy or preloaded bytes, network remains usable', () async {
    await legacy.put(key, Uint8List.fromList([1]));
    await a.read(key);
    await dbB.execute('DROP TABLE news_store_suppression');
    var fallbackCalls = 0;
    final read = await a.read(key, legacyFallback: () async { fallbackCalls++; return Uint8List.fromList([2]); });
    expect(read.state, NewsImageReadState.unknown);
    expect(fallbackCalls, 0);
    expect(await a.getOrFetch(key, () async => Uint8List.fromList([3])), [3]);
  });

  test('delayed fetch cannot return bytes after other instance invalidation', () async {
    final requested = Completer<void>(), release = Completer<Uint8List?>();
    final old = a.getOrFetch(key, () { requested.complete(); return release.future; });
    await requested.future;
    await b.invalidate(key.path);
    release.complete(Uint8List.fromList([1]));
    expect(await old, isNull);
    expect((await a.read(key)).state, NewsImageReadState.miss);
  });

  test('old in-flight completion does not remove the new one', () async {
    final firstStarted = Completer<void>(), first = Completer<Uint8List?>();
    final firstFuture = a.getOrFetch(key, () { firstStarted.complete(); return first.future; });
    await firstStarted.future;
    await a.invalidate(key.path);
    final secondStarted = Completer<void>(), second = Completer<Uint8List?>();
    var secondCalls = 0;
    final secondFuture = a.getOrFetch(key, () { secondCalls++; secondStarted.complete(); return second.future; });
    await secondStarted.future;
    first.complete(Uint8List.fromList([1]));
    expect(await firstFuture, isNull);
    final joined = a.getOrFetch(key, () async { secondCalls++; return Uint8List.fromList([9]); });
    second.complete(Uint8List.fromList([2]));
    expect(await secondFuture, [2]);
    expect(await joined, [2]);
    expect(secondCalls, 1);
  });

  test('ambiguous commit closes only owned connection before reopening', () async {
    final path = '${root.path}/reopen.db', blobRoot = Directory('${root.path}/reopen-blobs');
    final owned = await NewsSqliteImageStore.openOwned(databasePath: path, root: blobRoot, factory: databaseFactoryFfi);
    final reader = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    final replacements = <NewsSqliteImageStore>[];
    var opens = 0;
    final cache = PublicNewsImageCache(legacy: legacy, budget: budget, openStore: () async {
      opens++;
      if (opens == 1) return owned;
      final fresh = await NewsSqliteImageStore.openOwned(databasePath: path, root: blobRoot, factory: databaseFactoryFfi);
      replacements.add(fresh);
      return fresh;
    });
    try {
      await owned.database.rawQuery('PRAGMA journal_mode=DELETE');
      expect(await owned.put(key, Uint8List.fromList([8]), await owned.capture(key)), isTrue);
      expect((await cache.read(key)).bytes, [8]);
      final ticket = await owned.capture(key);
      await reader.execute('BEGIN'); await reader.rawQuery('SELECT * FROM news_store_images');
      final entered = Completer<void>(), proceed = Completer<void>();
      owned.debugAfterBlobRename = () async { entered.complete(); await proceed.future; };
      final write = owned.put(key, Uint8List.fromList([1]), ticket).then((v) => v, onError: (Object _) => false);
      await entered.future;
      final queuedRead = cache.read(key);
      proceed.complete();
      expect(await write, isFalse);
      expect((await queuedRead).state, NewsImageReadState.unknown);
      await reader.execute('COMMIT');
      final recovered = await cache.read(key);
      expect(recovered.bytes, anyOf(equals([8]), equals([1])));
      expect(opens, 2);
      expect(owned.database.isOpen, isFalse);
    } finally {
      if (owned.database.isOpen) await owned.database.close();
      await reader.close();
      for (final replacement in replacements) { await replacement.database.close(); }
    }
  });

  test('slow budget scan does not delay the fetched image or resurrect after clear', () async {
    final rootsReady = Completer<List<Directory>>();
    final delayedBudget = OptionalImageCacheBudget(roots: () => rootsReady.future);
    final cache = PublicNewsImageCache(legacy: legacy, openStore: () async => storeA, budget: delayedBudget);
    expect(await cache.getOrFetch(key, () async => Uint8List.fromList([5]))
        .timeout(const Duration(seconds: 1)), [5]);
    expect(await storeA.read(key), isNull);
    await b.invalidate();
    rootsReady.complete([root]);
    await delayedBudget.refreshForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await storeA.read(key), isNull);
  });

  for (final overLimit in [false, true]) {
    test('stale public news measurement ${overLimit ? 'rejects' : 'retries'} persistence', () async {
      final measured = await Directory('${root.path}/measured').create();
      var now = Duration.zero;
      var scans = 0;
      final pending = Completer<List<Directory>>();
      final budget = OptionalImageCacheBudget(
          roots: () => ++scans == 1 ? Future.value([measured]) : pending.future,
          elapsed: () => now, refreshInterval: const Duration(seconds: 1), limitBytes: 10);
      await budget.refreshForTesting();
      if (overLimit) await File('${measured.path}/protected').writeAsBytes(List.filled(11, 1));
      now = const Duration(seconds: 2);
      final spy = _CountingStore(database: dbA, root: Directory('${root.path}/blobs'));
      final cache = PublicNewsImageCache(legacy: legacy, openStore: () async => spy, budget: budget);
      expect(await cache.getOrFetch(key, () async => Uint8List.fromList([5])), [5]);
      expect(spy.calls, 0);
      pending.complete([measured]);
      await budget.refreshForTesting();
      if (!overLimit) await spy.written.future.timeout(const Duration(seconds: 2));
      else await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(spy.calls, overLimit ? 0 : 1);
    });
  }

  test('home snapshot and story do not trust preloaded bytes after clear', () async {
    final httpClient = MockClient((_) async => http.Response('', 503));
    final client = SupabaseClient('https://example.invalid', 'synthetic', httpClient: httpClient);
    final service = HomeDashboardService(client: client,
        scheduleRepository: ScheduleRepository(client: client),
        learningRepository: SupabaseLearningRepository(client: client),
        publicImageCache: a, httpClient: httpClient);
    addTearDown(() { service.dispose(); client.dispose(); });
    final item = HomeNewsItem(id: 'n', title: 't', subtitle: '', body: '',
        icon: Icons.info, gradientColors: const [], type: HomeNewsType.update,
        createdAt: DateTime.utc(2026), imagePath: key.path,
        imageBytes: Uint8List.fromList([7]));
    expect((await service.validateNewsImages([item])).single.imageBytes, [7],
        reason: 'already displayed bytes remain available on an ordinary cache miss');
    await b.invalidate();
    final validated = await service.validateNewsImages([item]);
    expect(validated.single.imageBytes, isNull);
    expect(await service.resolveNewsImageBytes(item), isNull);
  });
}
