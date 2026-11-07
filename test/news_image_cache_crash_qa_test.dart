import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
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
      'collect-uncommitted',
      'collect-staged',
      'collect-unlink'
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
          expect(
              journal.single['state'],
              phase == 'collect-staged' || phase == 'collect-unlink'
                  ? 'staged'
                  : 'intent');
          final files = await Directory('${root.path}/images')
              .list()
              .where((item) => item is File)
              .toList();
          expect(files.any((item) => item.path.contains('.news-evict-')),
              phase != 'collect-intent' && phase != 'collect-unlink');
          final key = NewsImageCacheKey(path: 'synthetic', version: '1');
          await cache.put(key, Uint8List.fromList([1]));
          expect(await cache.peek(key), [2],
              reason: 'journal blocks a racing writer');
          final indexFile = File('${root.path}/images/index.json');
          final originalIndex = await indexFile.readAsString();
          if (phase == 'collect-unlink') {
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
            expect(await db.query('news_cache_qa_evictions'), isEmpty);
            await cache.put(key, Uint8List.fromList([1]));
            expect(await cache.peek(key), [1]);
          } else if (phase != 'collect-intent') {
            final duplicateName = '${'a' * 40}.${'b' * 64}.bin';
            await db.insert('news_cache_qa_blobs', {
              'directory': journal.single['directory'],
              'file': duplicateName
            });
            await db.insert('news_cache_qa_evictions', {
              'directory': journal.single['directory'],
              'file': duplicateName,
              'token': journal.single['token'],
              'state': 'staged'
            });
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
            expect(await db.query('news_cache_qa_evictions'), hasLength(2));
            await db.delete('news_cache_qa_evictions',
                where: 'file=?', whereArgs: [duplicateName]);
            await db.delete('news_cache_qa_blobs',
                where: 'file=?', whereArgs: [duplicateName]);
            final stagedFile = File(
                '${root.path}/images/.news-evict-${journal.single['token']}');
            final unexpectedOriginal =
                File('${root.path}/images/${journal.single['file']}');
            await unexpectedOriginal
                .writeAsBytes(await stagedFile.readAsBytes());
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
            expect(await unexpectedOriginal.exists(), isTrue);
            expect(await stagedFile.exists(), isTrue);
            await unexpectedOriginal.delete();
            final decoded = jsonDecode(originalIndex) as Map<String, dynamic>;
            (decoded[key.id] as Map<String, dynamic>)['file'] =
                journal.single['file'];
            await indexFile.writeAsString(jsonEncode(decoded), flush: true);
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
            expect(await db.query('news_cache_qa_evictions'), hasLength(1));
            await indexFile.writeAsString('{broken', flush: true);
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
            expect(await db.query('news_cache_qa_evictions'), hasLength(1));
            await indexFile.writeAsString(originalIndex, flush: true);
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                1);
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
          } else {
            expect(await cache.recoverQaOrphans(allOperationsParticipate: true),
                0);
            expect(await db.query('news_cache_qa_evictions'), isEmpty);
            await cache.put(key, Uint8List.fromList([1]));
            expect(await cache.peek(key), [1]);
          }
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
