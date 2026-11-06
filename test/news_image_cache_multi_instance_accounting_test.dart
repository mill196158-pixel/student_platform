import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('independent store instances can leave unindexed physical bytes', () async {
    final root = await Directory.systemTemp.createTemp('cache-accounting-proof-');
    final storeDir = Directory(p.join(root.path, 'store'));
    final draft = File(p.join(root.path, 'draft-sentinel'));
    try {
      await draft.writeAsString('keep');
      NewsImageDiskCache make() => NewsImageDiskCache(
        memory: NewsImageBytesCache(), rootOverride: () => storeDir,
        maxEntries: 10, maxTotalBytes: 1024);
      final a = make(), b = make();
      // Both capture an empty independent in-memory index before either write.
      await a.ensureReady();
      await b.ensureReady();
      final first = NewsImageCacheKey(path: 'synthetic/a', version: '1');
      final second = NewsImageCacheKey(path: 'synthetic/b', version: '1');
      await a.put(first, Uint8List.fromList([1, 1]));
      await b.put(second, Uint8List.fromList([2, 2, 2]));
      final fresh = make();
      expect(await fresh.peek(first), isNull);
      expect(await fresh.peek(second), [2, 2, 2]);
      final entries = await storeDir.list(followLinks: false).toList();
      final blobs = entries.whereType<File>().where((f) => p.extension(f.path) == '.bin').toList();
      expect(blobs, hasLength(2), reason: 'the first file remains physically present');
      expect((await Future.wait(blobs.map((file) => file.length()))).reduce((a, b) => a + b), 5);
      expect(await draft.readAsString(), 'keep');
    } finally {
      final base = await Directory.systemTemp.resolveSymbolicLinks();
      final resolved = await root.resolveSymbolicLinks();
      if (!p.isWithin(base, resolved) || !p.basename(resolved).startsWith('cache-accounting-proof-')) {
        throw StateError('Unsafe synthetic cleanup target');
      }
      await root.delete(recursive: true);
    }
  });
}
