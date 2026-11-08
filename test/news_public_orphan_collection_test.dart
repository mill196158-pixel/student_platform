import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root, blobs;
  late Database db;
  late NewsSqliteImageStore store;
  final key = NewsImageCacheKey(path: 'public/test', version: '1');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('public-gc-test-');
    blobs = Directory('${root.path}/blobs');
    db = await databaseFactoryFfi.openDatabase('${root.path}/index.db',
        options: OpenDatabaseOptions(singleInstance: false));
    store = NewsSqliteImageStore.forCollectionTest(database: db, root: blobs);
    expect(await store.put(key, Uint8List.fromList([1, 2]), await store.capture(key)), isTrue);
  });
  tearDown(() async { await db.close(); await root.delete(recursive: true); });

  File orphan() => File('${blobs.path}/${'z' * 32}.bin');

  test('only orphan public file is unlinked; referenced and unrelated remain', () async {
    await orphan().writeAsBytes([7, 8, 9]);
    final unrelated = await File('${root.path}/protected').writeAsBytes([4]);
    final result = await store.collectOrphaned(current: () => true);
    expect(result?.filesUnlinked, 1);
    expect(result?.namedBytesUnlinked, 3);
    expect(await orphan().exists(), isFalse);
    expect(await store.read(key), [1, 2]);
    expect(await unrelated.readAsBytes(), [4]);
  });

  test('cancel after listing prevents any new unlink', () async {
    await orphan().writeAsBytes([7]);
    final entered = Completer<void>(), release = Completer<void>();
    var current = true;
    store.debugAfterOrphanListing = () async { entered.complete(); await release.future; };
    final pending = store.collectOrphaned(current: () => current);
    await entered.future;
    current = false;
    release.complete();
    expect(await pending, isNull);
    expect(await orphan().exists(), isTrue);
  });

  test('failed unlink, unexpected entry or missing protocol earns no credit', () async {
    await orphan().writeAsBytes([7]);
    store.debugBeforeOrphanUnlink = (_) async => throw const FileSystemException('synthetic');
    expect((await store.collectOrphaned(current: () => true))?.filesUnlinked, 0);
    store.debugBeforeOrphanUnlink = null;
    final unknown = await File('${blobs.path}/unknown').writeAsBytes([3]);
    expect(await store.collectOrphaned(current: () => true), isNull);
    expect(await orphan().exists(), isTrue);
    await unknown.delete();
    await File('${blobs.path}/.news-store-protocol').delete();
    expect(await store.collectOrphaned(current: () => true), isNull);
    expect(await orphan().exists(), isTrue);
  });

  test('fresh insufficient budget triggers background collection without delaying display', () async {
    await orphan().writeAsBytes([7]);
    final measured = await Directory('${root.path}/measured').create();
    await File('${measured.path}/budget').writeAsBytes(List.filled(20, 1));
    final budget = OptionalImageCacheBudget(roots: () async => [measured], limitBytes: 10);
    await budget.refreshForTesting();
    final cache = PublicNewsImageCache(openStore: () async => store, budget: budget,
        legacy: NewsImageDiskCache(rootOverride: () => Directory('${root.path}/legacy'), memory: NewsImageBytesCache()));
    final fresh = NewsImageCacheKey(path: 'public/new', version: '1');
    expect(await cache.getOrFetch(fresh, () async => Uint8List.fromList([8])).timeout(const Duration(seconds: 1)), [8]);
    for (var i = 0; i < 100 && await orphan().exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await orphan().exists(), isFalse);
    expect(await store.read(key), [1, 2]);
  });

  for (final delayedRead in [false, true]) {
    test('collector preserves active ${delayedRead ? 'reader' : 'writer'} across handles', () async {
      final otherDb = await databaseFactoryFfi.openDatabase('${root.path}/index.db',
          options: OpenDatabaseOptions(singleInstance: false));
      final other = NewsSqliteImageStore.forCollectionTest(database: otherDb, root: blobs);
      try {
        await orphan().writeAsBytes([7]);
        final entered = Completer<void>(), release = Completer<void>();
        Future<Object?> work;
        if (delayedRead) {
          store.debugBeforeImageRead = () async { entered.complete(); await release.future; };
          work = store.read(key);
        } else {
          final next = NewsImageCacheKey(path: 'public/active', version: '1');
          final ticket = await store.capture(next);
          store.debugAfterBlobRename = () async { entered.complete(); await release.future; };
          work = store.put(next, Uint8List.fromList([4]), ticket);
        }
        await entered.future;
        final cleaning = other.collectOrphaned(current: () => true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        release.complete();
        expect(await work, delayedRead ? equals([1, 2]) : isTrue);
        await cleaning;
        store.debugBeforeImageRead = null;
        store.debugAfterBlobRename = null;
        if (!delayedRead) {
          expect(await store.read(NewsImageCacheKey(path: 'public/active', version: '1')), [4]);
        }
        expect(await store.read(key), [1, 2]);
      } finally { await otherDb.close(); }
    });
  }

  test('abrupt exit after orphan unlink leaves referenced index intact', () async {
    final crashRoot = await Directory.systemTemp.createTemp('public-gc-crash-');
    try {
      final child = await Process.start('flutter', ['test', '--no-pub', 'test/support/news_public_gc_crash_fixture.dart'],
          environment: {'SYNTHETIC_NEWS_GC_ROOT': crashRoot.path},
          includeParentEnvironment: true, runInShell: Platform.isWindows);
      final out = child.stdout.transform(utf8.decoder).join(), err = child.stderr.transform(utf8.decoder).join();
      int code;
      try { code = await child.exitCode.timeout(const Duration(seconds: 90)); }
      on TimeoutException { child.kill(); await child.exitCode; rethrow; }
      expect(code, isNot(0));
      expect('${await out}${await err}', contains('SYNTHETIC_NEWS_GC_EXIT'));
      final reopened = await databaseFactoryFfi.openDatabase('${crashRoot.path}/index.db');
      try {
        final recovered = NewsSqliteImageStore.forCollectionTest(database: reopened,
            root: Directory('${crashRoot.path}/blobs'));
        expect(await recovered.read(key), [1, 2]);
        expect(await File('${crashRoot.path}/blobs/${'z' * 32}.bin').exists(), isFalse);
      } finally { await reopened.close(); }
    } finally { await crashRoot.delete(recursive: true); }
  });
}
