import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final clear in [true, false]) {
    test('late fetch cannot repopulate after ${clear ? 'clear' : 'invalidate'}',
        () async {
      final root = await Directory.systemTemp.createTemp('news_generation_');
      addTearDown(() => root.delete(recursive: true));
      final memory = NewsImageBytesCache();
      final cache =
          NewsImageDiskCache(rootOverride: () => root, memory: memory);
      final key = NewsImageCacheKey(path: 'race', version: '1');
      final started = Completer<void>(), response = Completer<Uint8List?>();
      final pending = cache.getOrFetch(key, () {
        started.complete();
        return response.future;
      });
      await started.future;
      if (clear) {
        await cache.clear();
      } else {
        await cache.invalidatePath(key.path);
      }
      response.complete(Uint8List.fromList([9]));
      expect(await pending, isNull);
      final fresh = NewsImageDiskCache(
          rootOverride: () => root, memory: NewsImageBytesCache());
      expect(await fresh.peek(key), isNull);
      expect(memory.peek(key), isNull);
    });
  }
  test('clear drains in-flight disk write before completing', () async {
    final root = await Directory.systemTemp.createTemp('news_generation_');
    addTearDown(() => root.delete(recursive: true));
    final cache = NewsImageDiskCache(
        rootOverride: () => root, memory: NewsImageBytesCache());
    final key = NewsImageCacheKey(path: 'race', version: '1');
    final started = Completer<void>(), release = Completer<void>();
    cache.debugAfterFileWrite = () async {
      started.complete();
      await release.future;
    };
    final put = cache.put(key, Uint8List.fromList([7]));
    await started.future;
    final clear = cache.clear();
    final during = cache.peek(key);
    release.complete();
    await put;
    await clear;
    expect(await during, isNull);
    expect(
        await NewsImageDiskCache(
                rootOverride: () => root, memory: NewsImageBytesCache())
            .peek(key),
        isNull);
  });
  test('memory hit remains immediate and does not call fetch', () async {
    final root = await Directory.systemTemp.createTemp('news_generation_');
    addTearDown(() => root.delete(recursive: true));
    final cache = NewsImageDiskCache(
        rootOverride: () => root, memory: NewsImageBytesCache());
    final key = NewsImageCacheKey(path: 'hot', version: '1');
    await cache.put(key, Uint8List.fromList([3]));
    var called = false;
    expect(
        await cache.getOrFetch(key, () async {
          called = true;
          return null;
        }),
        [3]);
    expect(called, isFalse);
  });
}
