import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  late NewsImageBytesCache cache;

  setUp(() {
    cache = NewsImageBytesCache(maxEntries: 4, maxTotalBytes: 1024);
  });

  NewsImageCacheKey key(String path, String version) =>
      NewsImageCacheKey(path: path, version: version);

  test('peek/put round-trip by path+version', () {
    final k = key('news/a.png', '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    cache.put(k, bytes);
    expect(cache.peek(k), bytes);
    expect(cache.peek(key('news/a.png', '2')), isNull);
  });

  test('single-flight: concurrent getOrFetch downloads once', () async {
    var downloads = 0;
    final k = key('news/a.png', '3');
    Future<Uint8List?> fetch() async {
      downloads += 1;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return Uint8List.fromList([9, 9, 9]);
    }

    final results = await Future.wait([
      cache.getOrFetch(k, fetch),
      cache.getOrFetch(k, fetch),
      cache.getOrFetch(k, fetch),
    ]);

    expect(downloads, 1);
    expect(cache.downloadCount, 1);
    expect(results.every((e) => e != null && e.length == 3), isTrue);
  });

  test('version change misses old entry (invalidate by new key)', () async {
    final v1 = key('news/a.png', '1');
    final v2 = key('news/a.png', '2');
    cache.put(v1, Uint8List.fromList([1]));
    expect(cache.peek(v1), isNotNull);
    expect(cache.peek(v2), isNull);

    await cache.getOrFetch(v2, () async => Uint8List.fromList([2]));
    expect(cache.peek(v2), isNotNull);
    expect(cache.downloadCount, 1);
  });

  test('invalidatePath drops all versions for path', () {
    cache.put(key('news/a.png', '1'), Uint8List.fromList([1]));
    cache.put(key('news/a.png', '2'), Uint8List.fromList([2]));
    cache.put(key('news/b.png', '1'), Uint8List.fromList([3]));
    cache.invalidatePath('news/a.png');
    expect(cache.peek(key('news/a.png', '1')), isNull);
    expect(cache.peek(key('news/a.png', '2')), isNull);
    expect(cache.peek(key('news/b.png', '1')), isNotNull);
  });

  test('network error keeps previous cached bytes', () async {
    final k = key('news/a.png', '1');
    cache.put(k, Uint8List.fromList([7, 7]));
    final before = cache.peek(k);
    final result = await cache.getOrFetch(k, () async => null);
    expect(result, before);
    expect(cache.peek(k), before);
    expect(cache.downloadCount, 0);
  });

  test('clear empties private cache', () {
    cache.put(key('news/a.png', '1'), Uint8List.fromList([1]));
    cache.clear();
    expect(cache.entryCount, 0);
    expect(cache.peek(key('news/a.png', '1')), isNull);
  });

  test('LRU evicts when over maxEntries', () {
    for (var i = 0; i < 5; i++) {
      cache.put(key('news/$i.png', '1'), Uint8List.fromList([i]));
    }
    expect(cache.entryCount, lessThanOrEqualTo(4));
    expect(cache.peek(key('news/0.png', '1')), isNull);
  });
}
