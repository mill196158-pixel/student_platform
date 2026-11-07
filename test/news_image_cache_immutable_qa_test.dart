import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
      'immutable QA keeps published bytes before and after a failed publication and merges handles',
      () async {
    final root = await Directory.systemTemp.createTemp('news-immutable-');
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final folder = Directory('${root.path}/images');
    NewsImageDiskCache create(Database db) => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final first = create(db1), second = create(db2);
    addTearDown(() async {
      await db2.close();
      await db1.close();
      await root.delete(recursive: true);
    });
    final a = NewsImageCacheKey(path: 'a', version: '1');
    final b = NewsImageCacheKey(path: 'b', version: '1');
    await first.put(a, Uint8List.fromList([1]));
    await second.ensureReady();
    first.debugBeforeImmutablePublish =
        () async => throw StateError('before publish');
    await first.put(a, Uint8List.fromList([2]));
    expect(await create(db1).peek(a), [1]);
    first.debugBeforeImmutablePublish = null;
    first.debugAfterImmutablePublish =
        () async => throw StateError('after publish');
    await first.put(a, Uint8List.fromList([3]));
    expect(await create(db1).peek(a), [3]);
    await second.put(b, Uint8List.fromList([4]));
    final reopened = create(db1);
    expect(await reopened.peek(a), [3]);
    expect(await reopened.peek(b), [4]);
    expect(await folder.list().where((x) => x.path.endsWith('.bin')).length, 4);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test('other handle clear and invalidate prevent late fetch publication',
      () async {
    final root = await Directory.systemTemp.createTemp('news-epochs-');
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final folder = Directory('${root.path}/images');
    NewsImageDiskCache make(Database db) => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final first = make(db1), second = make(db2);
    addTearDown(() async {
      await db2.close();
      await db1.close();
      await root.delete(recursive: true);
    });
    for (final clear in [true, false]) {
      final key =
          NewsImageCacheKey(path: clear ? 'clear' : 'invalidate', version: '1');
      final started = Completer<void>(), release = Completer<Uint8List?>();
      final pending = first.getOrFetch(key, () {
        started.complete();
        return release.future;
      });
      await started.future;
      if (clear) {
        await second.clear();
      } else {
        await second.invalidatePath(key.path);
      }
      release.complete(Uint8List.fromList([9]));
      expect(await pending, isNull);
      expect(await make(db1).peek(key), isNull);
    }
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test('clear intent recovery does not erase a newer publication', () async {
    final root = await Directory.systemTemp.createTemp('news-clear-intent-');
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final folder = Directory('${root.path}/images');
    NewsImageDiskCache make(Database db) => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final first = make(db1), second = make(db2);
    addTearDown(() async {
      await db2.close();
      await db1.close();
      await root.delete(recursive: true);
    });
    final key = NewsImageCacheKey(path: 'a', version: '1');
    await first.put(key, Uint8List.fromList([1]));
    final intent = Completer<void>(), release = Completer<void>();
    first.debugAfterClearIntent = () async {
      intent.complete();
      await release.future;
    };
    final clear = first.clear();
    await intent.future;
    await second.put(key, Uint8List.fromList([2]));
    release.complete();
    await clear;
    expect(await make(db1).peek(key), [2]);
    first.debugAfterClearIntent =
        () async => throw StateError('synthetic process stopped');
    await expectLater(first.clear(), throwsStateError);
    expect(await make(db2).peek(key), isNull);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test('prune intent preserves kept version and a newer version publication',
      () async {
    final root = await Directory.systemTemp.createTemp('news-prune-intent-');
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final folder = Directory('${root.path}/images');
    NewsImageDiskCache make(Database db) => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final first = make(db1), second = make(db2);
    addTearDown(() async {
      await db2.close();
      await db1.close();
      await root.delete(recursive: true);
    });
    final old = NewsImageCacheKey(path: 'a', version: '1');
    final keep = NewsImageCacheKey(path: 'a', version: '2');
    await first.put(old, Uint8List.fromList([1]));
    await first.put(keep, Uint8List.fromList([2]));
    final started = Completer<void>(), release = Completer<void>();
    first.debugAfterClearIntent = () async {
      started.complete();
      await release.future;
    };
    final prune = first.pruneOtherVersions('a', '2');
    await started.future;
    await second.put(old, Uint8List.fromList([3]));
    release.complete();
    await prune;
    expect(await make(db1).peek(keep), [2]);
    expect(await make(db1).peek(old), [3]);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test(
      'three synthetic cache directories stay isolated with one SQLite coordinator',
      () async {
    final root = await Directory.systemTemp.createTemp('news-three-roots-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    NewsImageDiskCache make(String name) => NewsImageDiskCache(
        rootOverride: () => Directory('${root.path}/$name'),
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    const names = [
      'news_images_v1',
      'guest_news_images_v1',
      'content_media_images_v1'
    ];
    final key = NewsImageCacheKey(path: 'same', version: '1');
    for (var i = 0; i < names.length; i++) {
      await make(names[i]).put(key, Uint8List.fromList([i + 1]));
    }
    await make(names[0]).clear();
    expect(await make(names[0]).peek(key), isNull);
    expect(await make(names[1]).peek(key), [2]);
    expect(await make(names[2]).peek(key), [3]);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test('legacy index entries remain readable and safe to replace', () async {
    final root = await Directory.systemTemp.createTemp('news-legacy-index-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
    final folder = Directory('${root.path}/images');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    NewsImageDiskCache make() => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final key = NewsImageCacheKey(path: 'legacy', version: '1');
    await folder.create(recursive: true);
    await File('${folder.path}/legacy.bin').writeAsBytes([1]);
    await File('${folder.path}/index.json').writeAsString(jsonEncode({
      key.id: {
        'file': 'legacy.bin',
        'bytes': 1,
        'path': key.path,
        'version': key.version,
        'lastAccess': DateTime.now().toUtc().toIso8601String()
      }
    }));
    expect(await make().peek(key), [1]);
    await make().put(key, Uint8List.fromList([2]));
    expect(await make().peek(key), [2]);
    expect(
        await folder.list().where((file) => file.path.endsWith('.bin')).length,
        2);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test(
      'unavailable coordination cannot return memory cleared by another handle',
      () async {
    final root = await Directory.systemTemp.createTemp('news-db-failure-');
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final folder = Directory('${root.path}/images');
    NewsImageDiskCache make(Database db) => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final first = make(db1), second = make(db2);
    addTearDown(() async {
      await db2.close();
      await root.delete(recursive: true);
    });
    final key = NewsImageCacheKey(path: 'a', version: '1');
    await first.put(key, Uint8List.fromList([1]));
    expect(await first.peek(key), [1]);
    await second.clear();
    await db1.close();
    expect(await first.peek(key), isNull);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test(
      'collector protects referenced and unknown blobs and blocks a racing writer',
      () async {
    final root = await Directory.systemTemp.createTemp('news-collect-');
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/locks.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final folder = Directory('${root.path}/images');
    NewsImageDiskCache make(Database db) => NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final first = make(db1), second = make(db2);
    addTearDown(() async {
      await db2.close();
      await db1.close();
      await root.delete(recursive: true);
    });
    final key = NewsImageCacheKey(path: 'a', version: '1');
    await first.put(key, Uint8List.fromList([1]));
    await first.put(key, Uint8List.fromList([2, 3]));
    final unknown = File('${folder.path}/unknown.bin');
    await unknown.writeAsBytes([7]);
    expect(await first.collectQaOrphans(allOperationsParticipate: false), 0);
    final started = Completer<void>(), release = Completer<void>();
    first.debugAfterCollectorIntent = () async {
      started.complete();
      await release.future;
    };
    final collecting = first.collectQaOrphans(allOperationsParticipate: true);
    await started.future;
    await second.put(key, Uint8List.fromList([1]));
    expect(await make(db2).peek(key), [2, 3]);
    release.complete();
    expect(await collecting, 1);
    expect(await make(db1).peek(key), [2, 3]);
    expect(await unknown.readAsBytes(), [7]);
    expect(await first.collectQaOrphans(allOperationsParticipate: true), 0);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test(
      'read-through uses legacy bytes without network or migration and clear suppresses fallback',
      () async {
    final root = await Directory.systemTemp.createTemp('news-legacy-read-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
    final legacy = Directory('${root.path}/legacy');
    final current = Directory('${root.path}/current');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await legacy.create(recursive: true);
    final key = NewsImageCacheKey(path: 'legacy', version: '1');
    final name = '${sha1.convert(utf8.encode(key.id))}.bin';
    final legacyFile = File('${legacy.path}/$name');
    await legacyFile.writeAsBytes([3, 4]);
    await File('${legacy.path}/index.json').writeAsString(jsonEncode({
      key.id: {
        'file': name,
        'bytes': 2,
        'path': key.path,
        'version': key.version,
        'lastAccess': DateTime.now().toUtc().toIso8601String()
      }
    }));
    NewsImageDiskCache make() => NewsImageDiskCache(
        rootOverride: () => current,
        legacyQaRootOverride: () => legacy,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    var networkCalled = false;
    expect(
        await make().getOrFetch(key, () async {
          networkCalled = true;
          return null;
        }),
        [3, 4]);
    expect(networkCalled, isFalse);
    expect(await make().collectQaOrphans(allOperationsParticipate: true), 0);
    expect(await legacyFile.readAsBytes(), [3, 4]);
    await make().pruneOtherVersions(key.path, key.version);
    expect(await make().peek(key), [3, 4]);
    await make().clear();
    expect(await make().peek(key), isNull);
    expect(await legacyFile.readAsBytes(), [3, 4]);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
  test('unknown namespace protocol fails closed and does not touch files',
      () async {
    final root =
        await Directory.systemTemp.createTemp('news-unknown-protocol-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/locks.db');
    final folder = Directory('${root.path}/images');
    await folder.create(recursive: true);
    final sentinel = File('${folder.path}/sentinel');
    await sentinel.writeAsBytes([8]);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.execute(
        'CREATE TABLE news_cache_qa_protocols (directory TEXT PRIMARY KEY, version INTEGER NOT NULL)');
    await db.insert('news_cache_qa_protocols',
        {'directory': folder.absolute.path, 'version': 99});
    final cache = NewsImageDiskCache(
        rootOverride: () => folder,
        memory: NewsImageBytesCache(),
        immutableQaDatabase: db);
    final key = NewsImageCacheKey(path: 'a', version: '1');
    expect(await cache.peek(key), isNull);
    await expectLater(
        cache.put(key, Uint8List.fromList([1])), throwsStateError);
    expect(await cache.collectQaOrphans(allOperationsParticipate: true), 0);
    expect(await sentinel.readAsBytes(), [8]);
  }, skip: !const bool.fromEnvironment('NEWS_CACHE_IMMUTABLE_QA'));
}
