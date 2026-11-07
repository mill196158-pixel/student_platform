import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('process exit before and after immutable index publication', () async {
    sqfliteFfiInit();
    for (final phase in [
      'before',
      'after',
      'clear',
      'collect-intent',
      'collect-staged'
    ]) {
      final root = await Directory.systemTemp.createTemp('news-publish-crash-');
      try {
        final child = await Process.run(
                'flutter',
                [
                  'test',
                  '--no-pub',
                  '--dart-define=NEWS_CACHE_IMMUTABLE_QA=true',
                  'test/support/news_immutable_crash_fixture.dart'
                ],
                environment: {
                  'SYNTHETIC_NEWS_ROOT': root.path,
                  'SYNTHETIC_NEWS_PHASE': phase
                },
                includeParentEnvironment: true,
                runInShell: Platform.isWindows)
            .timeout(const Duration(seconds: 90));
        expect(child.exitCode, isNot(0));
        expect(
            '${child.stdout}${child.stderr}', contains('SYNTHETIC_NEWS_CRASH'));
        final db =
            await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
        final cache = NewsImageDiskCache(
            rootOverride: () => Directory('${root.path}/images'),
            memory: NewsImageBytesCache(),
            immutableQaDatabase: db);
        expect(
            await cache
                .peek(NewsImageCacheKey(path: 'synthetic', version: '1')),
            phase == 'before' ? [1] : (phase == 'clear' ? null : [2]));
        if (phase.startsWith('collect')) {
          final journal = await db.query('news_cache_qa_evictions');
          expect(journal, hasLength(1));
          expect(journal.single['state'],
              phase == 'collect-intent' ? 'intent' : 'staged');
          final files = await Directory('${root.path}/images')
              .list()
              .where((item) => item is File)
              .toList();
          expect(files.any((item) => item.path.contains('.news-evict-')),
              phase == 'collect-staged');
        }
        await db.close();
      } finally {
        try {
          await root.delete(recursive: true);
        } catch (_) {
          /* Windows may briefly retain the child's SQLite handle. */
        }
      }
    }
  },
      skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'),
      timeout: const Timeout(Duration(seconds: 180)));
}
