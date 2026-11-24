import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory sandbox, temp, databases, blobs;
  late String index;
  late Database db;
  late NewsSqliteImageStore writer;
  late OptionalImageCacheBudget budget;
  final key = NewsImageCacheKey(path: 'public/news', version: 'v1');

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('news-manual-clear-');
    temp = await Directory('${sandbox.path}/temp').create();
    databases = await Directory('${sandbox.path}/databases').create();
    blobs = Directory('${temp.path}/public_news_blobs_v2');
    index = '${databases.path}/public_news_index_v2.db';
    db = await databaseFactoryFfi.openDatabase(index,
        options: OpenDatabaseOptions(singleInstance: false));
    writer = NewsSqliteImageStore.forCollectionTest(database: db, root: blobs);
    budget = OptionalImageCacheBudget(roots: () async => [temp]);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    await budget.refreshForTesting();
    await sandbox.delete(recursive: true);
  });

  Future<NewsSqliteImageStore?> openExisting() =>
      NewsSqliteImageStore.openExistingPublicNewsForTest(
          temp, databases, databaseFactoryFfi);

  Future<void> seed() async {
    expect(await writer.put(key, Uint8List.fromList([1, 2]), await writer.capture(key)), isTrue);
  }

  test('clears multiple batches, suppresses legacy and fences stale tickets across handles', () async {
    await seed();
    final old = await writer.capture(key);
    // One referenced copy plus 17 known-format orphans spans two batches.
    for (var i = 0; i < 17; i++) {
      await File('${blobs.path}/${i.toString().padLeft(32, '0')}.bin').writeAsBytes([3]);
    }
    final protected = await File('${temp.path}/offline-user-copy').writeAsBytes([6]);
    final store = (await openExisting())!;
    final cache = PublicNewsImageCache(openStore: () async => store, budget: budget);
    try {
      final first = cache.clearStoredCopies();
      expect(identical(first, cache.clearStoredCopies()), isTrue);
      final result = await first;
      expect(result.status, PublicNewsClearStatus.complete);
      expect(result.filesRemoved, 18);
      expect(await writer.put(key, Uint8List.fromList([7]), old), isFalse);
      final read = await writer.readWithLegacy(key,
          () async => fail('cleared rows must not fall back to legacy'));
      expect(read.state, NewsImageReadState.miss);
      expect(await protected.readAsBytes(), [6]);
      expect((await blobs.list().toList()), hasLength(1));
      final repeat = await cache.clearStoredCopies();
      expect(repeat.status, PublicNewsClearStatus.complete);
      expect(repeat.filesRemoved, 0);
      expect(await writer.put(key, Uint8List.fromList([8]), await writer.capture(key)), isTrue);
      expect(await writer.read(key), [8]);
    } finally {
      await store.database.close();
    }
  });

  test('a delayed fetch cannot resurrect the previous copy after user clear', () async {
    await seed();
    final cache = PublicNewsImageCache(openStore: () async => writer, budget: budget);
    final pendingKey = NewsImageCacheKey(path: 'public/pending', version: 'v1');
    final started = Completer<void>(), fetched = Completer<Uint8List?>();
    final work = cache.getOrFetch(pendingKey, () {
      started.complete();
      return fetched.future;
    });
    await started.future;
    expect((await cache.clearStoredCopies()).status, PublicNewsClearStatus.complete);
    fetched.complete(Uint8List.fromList([5]));
    expect(await work, isNull);
    expect(await writer.read(pendingKey), isNull);
  });

  test('an unlink failure is partial and can be retried after index commit', () async {
    await seed();
    writer.debugBeforeOrphanUnlink = (_) async => throw const FileSystemException('test');
    final cache = PublicNewsImageCache(openStore: () async => writer, budget: budget);
    final partial = await cache.clearStoredCopies();
    expect(partial.status, PublicNewsClearStatus.partial);
    expect(partial.filesRemoved, 0);
    expect(await writer.read(key), isNull);
    expect(await blobs.list().length, 2);
    writer.debugBeforeOrphanUnlink = null;
    final retry = await cache.clearStoredCopies();
    expect(retry.status, PublicNewsClearStatus.complete);
    expect(retry.filesRemoved, 1);
  });

  test('manual collection makes progress in a large cache and leaves temp files alone', () async {
    await seed();
    final tempFile = await File('${blobs.path}/.unfinished.tmp').writeAsBytes([9]);
    for (var i = 0; i < 1024; i++) {
      File('${blobs.path}/${i.toString().padLeft(32, '0')}.bin').writeAsBytesSync([3]);
    }
    await writer.invalidateStoredPublicCopies();
    final first = await writer.collectAfterUserClear(current: () => true);
    expect(first?.filesUnlinked, 16);
    expect(first?.remainingCandidates, greaterThan(0));
    expect(await tempFile.readAsBytes(), [9]);
  });

  test('a stray file yields a partial result without blocking verified files', () async {
    await seed();
    final unknown = await File('${blobs.path}/unknown').writeAsBytes([3]);
    final cache = PublicNewsImageCache(openStore: () async => writer, budget: budget);
    final result = await cache.clearStoredCopies();
    expect(result.status, PublicNewsClearStatus.partial);
    expect(result.filesRemoved, 1);
    expect(await unknown.readAsBytes(), [3]);
  });

  test('missing stores stay absent, incomplete or corrupted stores are preserved', () async {
    await db.close();
    await File(index).delete();
    expect(await openExisting(), isNull);
    expect(await File(index).exists(), isFalse);
    expect(await blobs.exists(), isFalse);
    final sidecar = await File('$index-wal').writeAsBytes([1, 2]);
    await expectLater(openExisting(), throwsStateError);
    expect(await sidecar.readAsBytes(), [1, 2]);
    await sidecar.delete();
    await blobs.create();
    await expectLater(openExisting(), throwsStateError);
    expect(await File(index).exists(), isFalse);
    final damaged = await File(index).writeAsBytes([1, 2, 3, 4]);
    await expectLater(openExisting(), throwsA(anything));
    expect(await damaged.readAsBytes(), [1, 2, 3, 4]);
    expect(await blobs.list().isEmpty, isTrue);
  });

  test('a mismatched marker or unexpected index trigger leaves data intact', () async {
    await seed();
    final marker = File('${blobs.path}/.news-store-protocol');
    final valid = await marker.readAsString();
    final cache = PublicNewsImageCache(openStore: () async => writer, budget: budget);
    await marker.writeAsString('invalid');
    expect((await cache.clearStoredCopies()).status, PublicNewsClearStatus.unavailable);
    expect(await blobs.list().length, 2);
    await marker.writeAsString(valid);
    await db.execute('CREATE TRIGGER test_trigger BEFORE DELETE ON news_store_images '
        'BEGIN SELECT 1; END');
    expect((await cache.clearStoredCopies()).status, PublicNewsClearStatus.unavailable);
    expect(await writer.read(key), [1, 2]);
  });
}
