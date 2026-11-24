import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:student_platform/src/core/attachment_storage_inventory.dart';

void main() {
  late Directory root;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment_inventory_');
    cache = await Directory(path.join(root.path, 'cache')).create();
    // systemTemp itself can be a standard platform alias.
    cache = Directory(await cache.resolveSymbolicLinks());
  });
  tearDown(() async => root.delete(recursive: true));

  Future<File> sizedFile(String parent, String name, int bytes) async {
    final dir =
        await Directory(path.join(cache.path, parent)).create(recursive: true);
    return File(path.join(dir.path, name)).writeAsBytes(List.filled(bytes, 7));
  }

  AttachmentStorageInventory inventory(
          {int entryLimit = 4096, int depthLimit = 12}) =>
      AttachmentStorageInventory.forTesting(
          cacheRoot: () async => cache,
          entryLimit: entryLimit,
          depthLimit: depthLimit);

  test('reports mixed lengths across owners and preserves every file',
      () async {
    final draft =
        await sizedFile('authorized_chat_files/a/forward_1', 'draft', 19);
    await sizedFile('authorized_chat_files/b', 'blob', 5);
    final denial = await sizedFile('authorized_chat_files/b', 'blob.denied', 2);
    await sizedFile('chat_files', 'viewer', 7);
    final download = await sizedFile('downloaded_chat_files', 'offline', 11);
    await sizedFile('other', 'not-counted', 53);
    final report = await inventory().collect();
    expect(report.authorizedFilesBytes, 26);
    expect(report.viewerFilesBytes, 7);
    expect(report.downloadedFilesBytes, 11);
    for (final file in [draft, denial, download]) {
      expect(await file.readAsBytes(), everyElement(7));
    }
  });

  test('zero requires a completed listing of the application cache root',
      () async {
    final report = await inventory().collect();
    expect([
      report.authorizedFilesBytes,
      report.viewerFilesBytes,
      report.downloadedFilesBytes
    ], [
      0,
      0,
      0
    ]);
    expect(await cache.list().isEmpty, isTrue);
    final missing = Directory(path.join(cache.path, 'missing_root'));
    final bad =
        AttachmentStorageInventory.forTesting(cacheRoot: () async => missing);
    final unavailable = await bad.collect();
    expect([
      unavailable.authorizedFilesBytes,
      unavailable.viewerFilesBytes,
      unavailable.downloadedFilesBytes
    ], everyElement(isNull));
    expect(await missing.exists(), isFalse);
    final broken = AttachmentStorageInventory.forTesting(
        cacheRoot: () => throw StateError('unavailable'));
    expect((await broken.collect()).authorizedFilesBytes, isNull);
  });

  test('a wrong type or truncated category does not hide completed siblings',
      () async {
    await File(path.join(cache.path, 'authorized_chat_files'))
        .writeAsBytes([7]);
    await sizedFile('chat_files', 'viewer', 3);
    await sizedFile('downloaded_chat_files/a/b', 'deep', 1);
    final depth = await inventory(depthLimit: 1).collect();
    expect(depth.authorizedFilesBytes, isNull);
    expect(depth.viewerFilesBytes, 3);
    expect(depth.downloadedFilesBytes, isNull);
    for (var i = 0; i < 4; i++) {
      await sizedFile('downloaded_chat_files', 'file-$i', 2);
    }
    final bounded = await inventory(entryLimit: 3).collect();
    expect(bounded.downloadedFilesBytes, isNull);
    expect(bounded.viewerFilesBytes, 3);
    final parentTruncated = await inventory(entryLimit: 1).collect();
    expect([
      parentTruncated.authorizedFilesBytes,
      parentTruncated.viewerFilesBytes,
      parentTruncated.downloadedFilesBytes
    ], everyElement(isNull));
  });

  test('concurrent callers share the deadline even if the root plugin stalls',
      () async {
    var calls = 0;
    final wait = Completer<Directory>();
    final scan = AttachmentStorageInventory.forTesting(
        cacheRoot: () {
          calls++;
          return wait.future;
        },
        timeout: const Duration(milliseconds: 50));
    final first = scan.collect();
    expect(identical(first, scan.collect()), isTrue);
    expect((await first).viewerFilesBytes, isNull);
    expect(identical(first, scan.collect()), isTrue);
    expect(calls, 1);
    wait.complete(cache);
    await Future<void>.delayed(Duration.zero);
    expect(identical(first, scan.collect()), isFalse);
    await scan.collect();
    expect(calls, 2);
  });

  test(
      'canonical platform root aliases work, final or descendant links give unknown',
      () async {
    Future<void> linkDir(String name, String target) async {
      if (Platform.isWindows) {
        final result = await Process.run('cmd.exe', [
          '/c',
          'mklink',
          '/J',
          path.normalize(name),
          path.normalize(target)
        ]);
        expect(result.exitCode, 0);
      } else {
        await Link(name).create(target);
      }
    }

    Future<void> removeLink(String name) async {
      final kind = await FileSystemEntity.type(name, followLinks: false);
      if (kind == FileSystemEntityType.link) {
        await Link(name).delete();
      } else if (kind == FileSystemEntityType.directory) {
        await Directory(name).delete();
      }
    }

    final linkedBase = path.join(root.path, 'redirect');
    final badRoot = path.join(cache.path, 'authorized_chat_files');
    final nested = path.join(cache.path, 'chat_files', 'redirect');
    final external = await Directory(path.join(root.path, 'external')).create();
    final sentinel = await File(path.join(external.path, 'sentinel'))
        .writeAsBytes([91, 92, 93]);
    await sizedFile('chat_files', 'viewer', 9);
    try {
      await linkDir(linkedBase, root.path);
      final alias = Directory(path.join(linkedBase, 'cache'));
      final trusted = AttachmentStorageInventory.forTesting(
          cacheRoot: () async => alias, platformRoot: true);
      final strict =
          AttachmentStorageInventory.forTesting(cacheRoot: () async => alias);
      expect((await trusted.collect()).viewerFilesBytes, 9);
      expect((await strict.collect()).viewerFilesBytes, isNull);
      final direct = AttachmentStorageInventory.forTesting(
          cacheRoot: () async => Directory(linkedBase), platformRoot: true);
      expect((await direct.collect()).viewerFilesBytes, isNull);
      await linkDir(badRoot, external.path);
      await linkDir(nested, external.path);
      final report = await inventory().collect();
      expect(report.authorizedFilesBytes, isNull);
      expect(report.viewerFilesBytes, isNull);
      expect(report.downloadedFilesBytes, 0);
      expect(await sentinel.readAsBytes(), [91, 92, 93]);
    } finally {
      await removeLink(nested);
      await removeLink(badRoot);
      await removeLink(linkedBase);
    }
  });
}
