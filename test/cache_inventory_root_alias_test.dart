import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'platform ancestor alias works; untrusted, direct link, descendant and overlapping roots fail closed',
      () async {
    final root = await Directory.systemTemp.createTemp('inventory_alias_');
    final real = await Directory('${root.path}/real').create();
    final cache = await Directory('${real.path}/cache').create();
    final db = await Directory('${root.path}/db').create();
    final support = await Directory('${root.path}/support').create();
    final blobs =
        await Directory('${cache.path}/public_news_blobs_v2').create();
    await File('${blobs.path}/item').writeAsBytes([1, 2, 3]);
    final alias = '${root.path}/alias';
    final descendant = '${blobs.path}/linked';
    Future<void> createAlias(String name, String target) async {
      if (Platform.isWindows) {
        final result = await Process.run('cmd.exe', [
          '/c',
          'mklink',
          '/J',
          path.normalize(name),
          path.normalize(target)
        ]);
        if (result.exitCode != 0)
          throw StateError(
              'Unable to create synthetic junction: ${result.exitCode}, ${result.stderr}');
      } else {
        await Link(name).create(target);
      }
    }

    Future<void> removeAlias(String name) async {
      final type = await FileSystemEntity.type(name, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await Link(name).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(name).delete();
      }
    }

    try {
      await createAlias(alias, real.path);
      final pathViaAncestor = Directory('$alias/cache');
      Future<InventorySnapshot> collect(
          {required bool trusted, Directory? temp}) {
        final args = temp ?? pathViaAncestor;
        final collector = trusted
            ? CacheInventoryCollector.platformRootsForTesting(
                temporaryRoot: () async => args,
                databaseRoot: () async => db,
                supportRoot: () async => support)
            : CacheInventoryCollector(
                temporaryRoot: () async => args,
                databaseRoot: () async => db,
                supportRoot: () async => support);
        return collector.collect();
      }

      int? value(InventorySnapshot snapshot) => snapshot.observations
          .firstWhere((e) => e.name == 'public_news_blobs_v2')
          .bytes;
      expect(value(await collect(trusted: false)), isNull);
      expect(value(await collect(trusted: true)), 3);
      expect(
          value(await collect(trusted: true, temp: Directory(alias))), isNull);
      await createAlias(descendant, db.path);
      expect(value(await collect(trusted: true)), isNull);
      await removeAlias(descendant);
      final overlap = CacheInventoryCollector.platformRootsForTesting(
          temporaryRoot: () async => cache,
          databaseRoot: () async => blobs,
          supportRoot: () async => support);
      expect(value(await overlap.collect()), isNull);
    } finally {
      await removeAlias(descendant);
      await removeAlias(alias);
      await root.delete(recursive: true);
    }
  });
}
