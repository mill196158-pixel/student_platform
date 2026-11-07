import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/startup_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
      'QA coordinator counts physical v2 bytes and refuses cleanup without synthetic proof',
      () async {
    final root = await Directory.systemTemp.createTemp('news-qa-budget-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final legacy = Directory('${root.path}/news_images_v1');
    await legacy.create(recursive: true);
    final sentinel = File('${legacy.path}/legacy.bin');
    await sentinel.writeAsBytes([9, 9]);
    final key = NewsImageCacheKey(path: 'a', version: '1');
    final names = [
      'news_images_v1',
      'guest_news_images_v1',
      'content_media_images_v1'
    ];
    for (var i = 0; i < names.length; i++) {
      final folder = Directory('${root.path}/${names[i]}_immutable_qa_v2');
      final cache = NewsImageDiskCache(
          rootOverride: () => folder,
          memory: NewsImageBytesCache(),
          immutableQaDatabase: db);
      await cache.put(key, Uint8List.fromList(List.filled(i + 1, 1)));
      await cache.put(key, Uint8List.fromList([2, i]));
    }
    final blocked = await runQaNewsCacheMaintenance(
        limitBytes: 0, temporaryRoot: root, database: db);
    expect(blocked, isNotNull);
    expect(blocked!.confirmedFreedBytes, 0);
    expect(blocked.beforeBytes, blocked.afterBytes);
    final cleaned = await runQaNewsCacheMaintenance(
        limitBytes: 0,
        temporaryRoot: root,
        database: db,
        debugSyntheticEngineProof: () => true);
    expect(cleaned, isNotNull);
    expect(cleaned!.confirmedFreedBytes, 6);
    expect(cleaned.beforeBytes - cleaned.afterBytes, 6);
    expect(await sentinel.readAsBytes(), [9, 9]);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
}
