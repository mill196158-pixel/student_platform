import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('making another instance see an old index changes eviction candidates', () async {
    final root = await Directory.systemTemp.createTemp('cache-merge-risk-test-');
    final draft = File(p.join(root.path, 'draft-sentinel'));
    final offline = File(p.join(root.path, 'offline-sentinel'));
    try {
      await draft.writeAsString('draft stays');
      await offline.writeAsString('offline stays');
      Future<List<int>> scenario(String name, {required bool observeOldIndex}) async {
        final dir = Directory(p.join(root.path, name));
        NewsImageDiskCache make() => NewsImageDiskCache(
          memory: NewsImageBytesCache(), rootOverride: () => dir,
          maxEntries: 1, maxTotalBytes: 1024);
        final a = make(), b = make();
        await a.ensureReady();
        if (!observeOldIndex) await b.ensureReady();
        await a.put(NewsImageCacheKey(path: 'synthetic/old', version: '1'), Uint8List.fromList([1]));
        if (observeOldIndex) await b.ensureReady();
        await b.put(NewsImageCacheKey(path: 'synthetic/new', version: '1'), Uint8List.fromList([2]));
        final entries = await dir.list(followLinks: false).toList();
        final blobs = entries.whereType<File>().where((f) => p.extension(f.path) == '.bin');
        final values = <int>[];
        for (final file in blobs) { values.add((await file.readAsBytes()).single); }
        return values..sort();
      }
      expect(await scenario('stale-index', observeOldIndex: false), [1, 2],
          reason: 'unseen old blob is left on disk');
      expect(await scenario('visible-index', observeOldIndex: true), [2],
          reason: 'the existing LRU removes the old blob once the index includes it');
      expect(await draft.readAsString(), 'draft stays');
      expect(await offline.readAsString(), 'offline stays');
    } finally {
      final base = await Directory.systemTemp.resolveSymbolicLinks();
      final resolved = await root.resolveSymbolicLinks();
      if (!p.isWithin(base, resolved) || !p.basename(resolved).startsWith('cache-merge-risk-test-')) {
        throw StateError('Unsafe synthetic cleanup target');
      }
      await root.delete(recursive: true);
    }
  });
}
