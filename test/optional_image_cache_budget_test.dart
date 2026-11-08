import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('budget_test_'); });
  tearDown(() async { await root.delete(recursive: true); });

  test('nested roots and sqlite sidecars count once; reservations compete', () async {
    final db = await Directory('${root.path}/db').create();
    await File('${db.path}/history.db').writeAsBytes(List.filled(4, 1));
    await File('${db.path}/history.db-wal').writeAsBytes(List.filled(3, 1));
    await File('${db.path}/history.db-shm').writeAsBytes(List.filled(2, 1));
    final budget = OptionalImageCacheBudget(roots: () async => [root, db], limitBytes: 15);
    await budget.refreshForTesting();
    final first = budget.reserve(4);
    expect(first, isNotNull);
    expect(budget.reserve(3), isNull);
    first!();
    expect(budget.reserve(3), isNull);
    expect(await File('${db.path}/history.db').length(), 4);
  });

  test('rejected disk copy still returns image and preserves existing file', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final protected = File('${root.path}/draft');
    await protected.writeAsBytes(List.filled(20, 1));
    final budget = OptionalImageCacheBudget(roots: () async => [root], limitBytes: 10);
    await budget.refreshForTesting();
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot, memory: memory, debugOptionalBudget: budget);
    final key = NewsImageCacheKey(path: 'news/test', version: '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    expect(await disk.getOrFetch(key, () async => bytes), bytes);
    expect(await protected.length(), 20);
    memory.clear();
    expect(await disk.peek(key), isNull);
  });

  test('put keeps memory and previous disk entry when budget denies', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final oldMemory = NewsImageBytesCache();
    final oldDisk = NewsImageDiskCache(rootOverride: () => cacheRoot, memory: oldMemory);
    final oldKey = NewsImageCacheKey(path: 'news/old', version: '1');
    final oldBytes = Uint8List.fromList([7, 8]);
    await oldDisk.put(oldKey, oldBytes);
    final before = await File('${cacheRoot.path}/index.json').readAsBytes();
    final budget = OptionalImageCacheBudget(roots: () async => [root], limitBytes: 0);
    await budget.refreshForTesting();
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot, memory: memory, debugOptionalBudget: budget);
    final newKey = NewsImageCacheKey(path: 'news/new', version: '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    await disk.put(newKey, bytes);
    expect(await disk.peek(newKey), bytes);
    expect(await File('${cacheRoot.path}/index.json').readAsBytes(), before);
    memory.clear();
    expect(await disk.peek(newKey), isNull);
    expect(await disk.peek(oldKey), oldBytes);
  });

  test('unknown root denies optional image', () async {
    final budget = OptionalImageCacheBudget(roots: () async => [Directory('${root.path}/missing')], limitBytes: 0);
    await budget.refreshForTesting();
    final release = budget.reserve(1);
    expect(release, isNull);
  });

  test('first image displays while scan runs then persists once', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final rootsReady = Completer<List<Directory>>();
    final budget = OptionalImageCacheBudget(roots: () => rootsReady.future);
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot,
        memory: memory, debugOptionalBudget: budget);
    final key = NewsImageCacheKey(path: 'news/first', version: '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    await disk.put(key, bytes);
    expect(await disk.peek(key), bytes);
    expect(await File('${cacheRoot.path}/index.json').exists(), isFalse);
    rootsReady.complete([root]);
    for (var i = 0; i < 100 && !await File('${cacheRoot.path}/index.json').exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    memory.clear();
    expect(await disk.peek(key), bytes);
  });

  test('late measurement cannot restore an invalidated image', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final rootsReady = Completer<List<Directory>>();
    final budget = OptionalImageCacheBudget(roots: () => rootsReady.future);
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot,
        memory: memory, debugOptionalBudget: budget);
    final key = NewsImageCacheKey(path: 'news/removed', version: '1');
    await disk.put(key, Uint8List.fromList([1, 2, 3]));
    await disk.invalidatePath(key.path);
    rootsReady.complete([root]);
    await budget.refreshForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    memory.clear();
    expect(await disk.peek(key), isNull);
  });

  test('late measurement cannot restore an image after clear', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final rootsReady = Completer<List<Directory>>();
    final budget = OptionalImageCacheBudget(roots: () => rootsReady.future);
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot,
        memory: memory, debugOptionalBudget: budget);
    final key = NewsImageCacheKey(path: 'news/cleared', version: '1');
    await disk.put(key, Uint8List.fromList([1, 2, 3]));
    await disk.clear();
    rootsReady.complete([root]);
    await budget.refreshForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    memory.clear();
    expect(await disk.peek(key), isNull);
  });

  test('late measurement saves only replacement bytes for the same key', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final rootsReady = Completer<List<Directory>>();
    final budget = OptionalImageCacheBudget(roots: () => rootsReady.future);
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot,
        memory: memory, debugOptionalBudget: budget);
    final key = NewsImageCacheKey(path: 'news/replaced', version: '1');
    final newer = Uint8List.fromList([9, 8, 7]);
    await disk.put(key, Uint8List.fromList([1, 2, 3]));
    await disk.put(key, newer);
    rootsReady.complete([root]);
    for (var i = 0; i < 100 && !await File('${cacheRoot.path}/index.json').exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    memory.clear();
    expect(await disk.peek(key), newer);
  });

  test('timed-out scan cannot trigger a late disk write', () async {
    final cacheRoot = await Directory('${root.path}/cache').create();
    final rootsReady = Completer<List<Directory>>();
    final budget = OptionalImageCacheBudget(roots: () => rootsReady.future);
    final memory = NewsImageBytesCache();
    final disk = NewsImageDiskCache(rootOverride: () => cacheRoot,
        memory: memory, debugOptionalBudget: budget);
    final key = NewsImageCacheKey(path: 'news/timeout', version: '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    await disk.put(key, bytes);
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    rootsReady.complete([root]);
    await budget.refreshForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await disk.peek(key), bytes);
    memory.clear();
    expect(await disk.peek(key), isNull);
  });

  test('symlink inside measured root makes usage unknown', () async {
    final link = Link('${root.path}/linked');
    try { await link.create(root.path); } on FileSystemException { return; }
    final budget = OptionalImageCacheBudget(roots: () async => [root]);
    await budget.refreshForTesting();
    expect(budget.reserve(1), isNull);
  });
}
