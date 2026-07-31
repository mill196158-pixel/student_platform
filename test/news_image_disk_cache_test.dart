import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late NewsImageBytesCache memory;
  late NewsImageDiskCache disk;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('news_img_test_');
    memory = NewsImageBytesCache();
    disk = NewsImageDiskCache(
      memory: memory,
      rootOverride: () => tempDir,
      maxEntries: 3,
      maxTotalBytes: 10 * 1024,
    );
  });

  tearDown(() async {
    memory.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  NewsImageCacheKey key(String path, String version) =>
      NewsImageCacheKey(path: path, version: version);

  test('cached image is shown from disk before network fetch', () async {
    final k = key('news/a.png', '1');
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await disk.put(k, bytes);
    memory.clear();

    final peeked = await disk.peek(k);
    expect(peeked, bytes);

    var networkCalls = 0;
    final again = await disk.getOrFetch(k, () async {
      networkCalls += 1;
      return Uint8List.fromList([9]);
    });
    expect(networkCalls, 0);
    expect(again, bytes);
  });

  test('version change downloads new bytes; old path versions prune later',
      () async {
    final v1 = key('news/a.png', '1');
    final v2 = key('news/a.png', '2');
    await disk.put(v1, Uint8List.fromList([1]));
    var calls = 0;
    await disk.getOrFetch(v2, () async {
      calls += 1;
      return Uint8List.fromList([2, 2]);
    });
    expect(calls, 1);
    expect(await disk.peek(v2), isNotNull);

    await disk.pruneOtherVersions('news/a.png', '2');
    expect(await disk.peek(v1), isNull);
    expect(await disk.peek(v2), isNotNull);
  });

  test('network error keeps last good disk bytes', () async {
    final k = key('news/a.png', '1');
    await disk.put(k, Uint8List.fromList([7, 7, 7]));
    memory.clear();

    final result = await disk.getOrFetch(k, () async => null);
    expect(result, Uint8List.fromList([7, 7, 7]));
  });

  test('refresh merge keeps image bytes for same cache key', () {
    final previous = HomeNewsItem(
      id: 'n1',
      title: 'T',
      subtitle: 'S',
      body: 'B',
      icon: Icons.auto_awesome_rounded,
      gradientColors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
      type: HomeNewsType.update,
      createdAt: DateTime.utc(2026, 7, 1),
      updatedAt: DateTime.utc(2026, 7, 22),
      variant: StudentHomeNewsVariant.imageOverlay,
      imagePath: 'news/a.png',
      imageBytes: Uint8List.fromList([1, 2, 3]),
    );
    final next = previous.copyWith(clearImageBytes: true);
    expect(next.imageBytes, isNull);
    expect(previous.imageCacheKey?.id, next.imageCacheKey?.id);

    final merged = next.copyWith(imageBytes: previous.imageBytes);
    expect(merged.imageBytes, isNotNull);
  });

  test('eviction respects maxEntries', () async {
    for (var i = 0; i < 5; i++) {
      await disk.put(
        key('news/$i.png', '1'),
        Uint8List.fromList(List<int>.filled(16, i)),
      );
    }
    // Oldest should be gone after cap.
    expect(await disk.peek(key('news/0.png', '1')), isNull);
  });
}
