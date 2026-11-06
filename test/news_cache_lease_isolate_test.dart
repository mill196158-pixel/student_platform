import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/news_cache_lease.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';

Future<void> worker((String, SendPort) args) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final root = Directory(args.$1);
  args.$2.send('starting');
  try {
    await NewsCacheLease.run(root, () async => args.$2.send('entered'));
    await NewsCacheLease.debugClose(root);
    args.$2.send('done');
  } catch (error) {
    args.$2.send('error: $error');
  }
}

Future<void> cacheWorker((String, SendPort) args) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final root = Directory(args.$1);
  final cache = NewsImageDiskCache(rootOverride: () => root,
      memory: NewsImageBytesCache(maxEntries: 4), debugUseSqliteLease: true);
  args.$2.send('starting');
  try {
    await cache.put(const NewsImageCacheKey(path: 'second', version: '1'),
        Uint8List.fromList([2]));
    await NewsCacheLease.debugClose(root);
    args.$2.send('done');
  } catch (error) {
    args.$2.send('error: $error');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('SQLite lease serializes another isolate until reader releases', () async {
    final parent = await Directory.systemTemp.createTemp('news-lease-test-');
    final root = Directory('${parent.path}/cache');
    await root.create();
    final release = Completer<void>();
    final entered = Completer<void>();
    final messages = ReceivePort();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      messages.close();
      await NewsCacheLease.debugClose(root);
      if (parent.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await parent.delete(recursive: true);
      }
    });
    final first = NewsCacheLease.run(root, () async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final events = <String>[];
    final finished = Completer<void>();
    messages.listen((message) {
      events.add(message.toString());
      if (message == 'done' || message.toString().startsWith('error:')) {
        finished.complete();
      }
    });
    await Isolate.spawn(worker, (root.path, messages.sendPort));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(events, contains('starting'));
    expect(events, isNot(contains('entered')));
    release.complete();
    await first;
    await finished.future.timeout(const Duration(seconds: 8));
    expect(events, containsAllInOrder(['starting', 'entered', 'done']));
  });

  test('two isolates preserve both news index entries', () async {
    final parent = await Directory.systemTemp.createTemp('news-lease-cache-');
    final root = Directory('${parent.path}/cache');
    final release = Completer<void>();
    final entered = Completer<void>();
    final messages = ReceivePort();
    final cache = NewsImageDiskCache(rootOverride: () => root,
        memory: NewsImageBytesCache(maxEntries: 4), debugUseSqliteLease: true);
    cache.debugAfterFileWrite = () async { entered.complete(); await release.future; };
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      messages.close();
      await NewsCacheLease.debugClose(root);
      if (parent.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await parent.delete(recursive: true);
      }
    });
    final first = cache.put(const NewsImageCacheKey(path: 'first', version: '1'),
        Uint8List.fromList([1]));
    await entered.future;
    final events = <String>[];
    final finished = Completer<void>();
    messages.listen((message) {
      events.add(message.toString());
      if (message == 'done' || message.toString().startsWith('error:')) finished.complete();
    });
    await Isolate.spawn(cacheWorker, (root.path, messages.sendPort));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(events, contains('starting'));
    expect(events, isNot(contains('done')));
    release.complete();
    await first;
    await finished.future.timeout(const Duration(seconds: 8));
    expect(events, contains('done'));
    expect(await cache.peek(const NewsImageCacheKey(path: 'first', version: '1')), [1]);
    expect(await cache.peek(const NewsImageCacheKey(path: 'second', version: '1')), [2]);
  });

  test('cold disk read survives a lease failure and disables extra eviction', () async {
    final parent = await Directory.systemTemp.createTemp('news-lease-fallback-');
    final root = Directory('${parent.path}/cache');
    addTearDown(() async {
      if (parent.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await parent.delete(recursive: true);
      }
    });
    const key = NewsImageCacheKey(path: 'old', version: '1');
    final old = NewsImageDiskCache(rootOverride: () => root,
        memory: NewsImageBytesCache(maxEntries: 4));
    await old.put(key, Uint8List.fromList([8, 9]));
    final restored = NewsImageDiskCache(rootOverride: () => root,
        memory: NewsImageBytesCache(maxEntries: 4), debugUseSqliteLease: true);
    restored.debugBeforeLease = () async => throw StateError('database corrupt');
    expect(await restored.peek(key), [8, 9]);
    expect(await NewsCacheLease.disabledMarker(root).exists(), isTrue);
    const fresh = NewsImageCacheKey(path: 'network', version: '1');
    expect(await restored.getOrFetch(fresh, () async => Uint8List.fromList([7])), [7]);
    expect(await restored.peek(fresh), [7]);
  });

  test('legacy index remains readable after enabling the SQLite lease', () async {
    final parent = await Directory.systemTemp.createTemp('news-lease-migrate-');
    final root = Directory('${parent.path}/cache');
    addTearDown(() async {
      await NewsCacheLease.debugClose(root);
      if (parent.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await parent.delete(recursive: true);
      }
    });
    const key = NewsImageCacheKey(path: 'legacy', version: '1');
    final old = NewsImageDiskCache(rootOverride: () => root,
        memory: NewsImageBytesCache(maxEntries: 4));
    await old.put(key, Uint8List.fromList([5, 6]));
    final migrated = NewsImageDiskCache(rootOverride: () => root,
        memory: NewsImageBytesCache(maxEntries: 4), debugUseSqliteLease: true);
    expect(await migrated.peek(key), [5, 6]);
  });
}
