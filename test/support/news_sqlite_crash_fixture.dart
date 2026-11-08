import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('synthetic crash fixture', () async {
    final root = Platform.environment['SYNTHETIC_NEWS_SQLITE_ROOT'];
    final phase = Platform.environment['SYNTHETIC_NEWS_SQLITE_PHASE'];
    if (root == null || !['before', 'after'].contains(phase)) throw StateError('Synthetic fixture only');
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase('$root/store.db');
    final store = NewsSqliteImageStore(database: db, root: Directory('$root/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    await store.put(key, Uint8List.fromList([1]), await store.capture(key));
    Future<void> crash() async {
      stdout.writeln('SYNTHETIC_SQLITE_NEWS_CRASH');
      await stdout.flush();
      exit(73);
    }
    if (phase == 'before') store.debugAfterBlobRename = crash;
    if (phase == 'after') store.debugAfterCommit = crash;
    await store.put(key, Uint8List.fromList([2]), await store.capture(key));
    throw StateError('Crash hook did not fire');
  });
}
