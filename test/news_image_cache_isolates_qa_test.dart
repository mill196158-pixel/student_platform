import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

Future<void> writeInIsolate(String root, String key, int value) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase('$root/locks.db',
      options: OpenDatabaseOptions(singleInstance: false));
  final cache = NewsImageDiskCache(
      rootOverride: () => Directory('$root/images'),
      memory: NewsImageBytesCache(),
      immutableQaDatabase: db);
  await cache.put(
      NewsImageCacheKey(path: key, version: '1'), Uint8List.fromList([value]));
  await db.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('two isolates publish distinct images without losing the index',
      () async {
    final root = await Directory.systemTemp.createTemp('news-two-isolates-');
    try {
      await Future.wait([
        Isolate.run(() => writeInIsolate(root.path, 'a', 1)),
        Isolate.run(() => writeInIsolate(root.path, 'b', 2))
      ]);
      final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
      final cache = NewsImageDiskCache(
          rootOverride: () => Directory('${root.path}/images'),
          memory: NewsImageBytesCache(),
          immutableQaDatabase: db);
      expect(await cache.peek(NewsImageCacheKey(path: 'a', version: '1')), [1]);
      expect(await cache.peek(NewsImageCacheKey(path: 'b', version: '1')), [2]);
      await db.close();
    } finally {
      try {
        await root.delete(recursive: true);
      } catch (_) {
        /* Isolate SQLite worker may still hold the synthetic database. */
      }
    }
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
}
