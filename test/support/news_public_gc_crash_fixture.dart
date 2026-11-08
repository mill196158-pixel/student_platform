import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('synthetic exit after orphan unlink', () async {
    final root = Platform.environment['SYNTHETIC_NEWS_GC_ROOT'];
    if (root == null) return;
    final db = await databaseFactoryFfi.openDatabase('$root/index.db');
    final store = NewsSqliteImageStore.forCollectionTest(database: db, root: Directory('$root/blobs'));
    final key = NewsImageCacheKey(path: 'public/test', version: '1');
    if (!await store.put(key, Uint8List.fromList([1, 2]), await store.capture(key))) throw StateError('Synthetic put failed');
    await File('$root/blobs/${'z' * 32}.bin').writeAsBytes([7]);
    store.debugAfterOrphanUnlink = () async {
      stdout.writeln('SYNTHETIC_NEWS_GC_EXIT');
      await stdout.flush();
      exit(42);
    };
    await store.collectOrphaned(current: () => true);
    throw StateError('Expected synthetic exit');
  });
}
