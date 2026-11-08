import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a previously resolved directory path can address a replacement directory', () async {
    final sandbox = await Directory.systemTemp.createTemp('news-path-boundary-');
    try {
      final original = await Directory('${sandbox.path}/news').create();
      await File('${original.path}/sentinel').writeAsString('original');
      final checkedPath = await original.resolveSymbolicLinks();
      final moved = await original.rename('${sandbox.path}/original-moved');
      final replacement = await Directory('${sandbox.path}/news').create();

      // A path string is resolved again at write time; this does not prove
      // that the application's actual writer can be raced on a device.
      await File('$checkedPath/synthetic.bin').writeAsBytes([1]);
      expect(await File('${replacement.path}/synthetic.bin').exists(), isTrue);
      expect(await File('${moved.path}/synthetic.bin').exists(), isFalse);
      expect(await File('${moved.path}/sentinel').readAsString(), 'original');
    } finally {
      await sandbox.delete(recursive: true);
    }
  });
}
