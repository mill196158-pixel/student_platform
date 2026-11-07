import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('per-engine marker is held by a live process and released by crash',
      () async {
    final root = await Directory.systemTemp.createTemp('news-engine-lock-');
    final legacy = Directory('${root.path}/news_images_v1');
    final current = Directory('${root.path}/news_images_v1_immutable_qa_v2');
    await legacy.create();
    await current.create();
    final marker = File('${root.path}/engine-marker');
    final dart = Platform.isWindows
        ? '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/flutter'}/bin/cache/dart-sdk/bin/dart.exe'
        : 'dart';
    final child = await Process.start(dart,
        ['test/helpers/cache_guard_child.dart', marker.path, 'engine-token']);
    RandomAccessFile? probe;
    var childStopped = false;
    try {
      expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 8)),
          'ready');
      probe = await marker.open(mode: FileMode.append);
      await expectLater(
          probe.lock(FileLock.exclusive), throwsA(isA<FileSystemException>()));
      // An ordinary old writer uses only the old root.
      await File('${legacy.path}/index.json').writeAsString('legacy-write');
      expect(await current.list().isEmpty, isTrue);
      // A marker is not an access-control primitive for another file. An
      // uncooperative process with the v2 path could still write it.
      final arbitrary = File('${current.path}/uncooperative-sentinel');
      await arbitrary.writeAsString('unguarded');
      expect(await arbitrary.readAsString(), 'unguarded');
      expect(child.kill(), isTrue);
      await child.exitCode.timeout(const Duration(seconds: 8));
      childStopped = true;
      await probe.lock(FileLock.exclusive);
      await probe.unlock();
    } finally {
      if (!childStopped) {
        child.kill();
        await child.exitCode;
      }
      await probe?.close();
      await root.delete(recursive: true);
    }
  });
}
