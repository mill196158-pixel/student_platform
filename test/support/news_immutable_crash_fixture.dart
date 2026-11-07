import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('crash at immutable index publication', () async {
    sqfliteFfiInit();
    final root = Directory(Platform.environment['SYNTHETIC_NEWS_ROOT']!);
    final phase = Platform.environment['SYNTHETIC_NEWS_PHASE']!;
    final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
    final cache = NewsImageDiskCache(
        rootOverride: () => Directory('${root.path}/images'),
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final key = NewsImageCacheKey(path: 'synthetic', version: '1');
    await cache.put(key, Uint8List.fromList([1]));
    Future<void> crash() async {
      stdout.writeln('SYNTHETIC_NEWS_CRASH');
      await stdout.flush();
      exit(86);
    }

    if (phase.startsWith('collect')) {
      await cache.put(key, Uint8List.fromList([2]));
      if (phase == 'collect-intent') {
        cache.debugAfterCollectorIntent = crash;
      } else if (phase == 'collect-uncommitted') {
        cache.debugAfterCollectorRenameBeforeCommit = crash;
      } else if (phase == 'collect-unlink') {
        cache.debugAfterCollectorUnlinkBeforeCommit = crash;
      } else {
        cache.debugAfterCollectorRename = crash;
      }
      await cache.collectQaOrphans(allOperationsParticipate: true);
      throw StateError('Collector crash point not reached');
    }
    if (phase == 'clear') {
      cache.debugAfterClearIntent = crash;
      await cache.clear();
      throw StateError('Clear crash point not reached');
    }
    if (phase == 'before') {
      cache.debugBeforeImmutablePublish = crash;
    } else {
      cache.debugAfterImmutablePublish = crash;
    }
    await cache.put(key, Uint8List.fromList([2]));
    throw StateError('Crash point not reached');
  });
}
