import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';

void main() {
  test('concurrent viewers publish only complete cache files', () async {
    final directory = await Directory.systemTemp.createTemp('viewer-atomic-');
    try {
      final destination = File('${directory.path}/viewer.bin');
      final first = List<int>.filled(1024 * 1024, 7);
      final second = List<int>.filled(1024 * 1024, 9);
      final entered = Completer<void>(), release = Completer<void>();
      final old = writeViewerFileAtomically(destination, first,
          beforePublish: () async {
        entered.complete();
        await release.future;
      });
      final oldRejected = expectLater(old, throwsStateError);
      await entered.future;
      await writeViewerFileAtomically(destination, second);
      release.complete();
      await oldRejected;
      final bytes = await destination.readAsBytes();
      expect(bytes.length, first.length);
      expect(bytes.every((byte) => byte == 9), isTrue);
      expect(await directory.list().length, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('publish failure is not hidden by an existing directory', () async {
    final directory = await Directory.systemTemp.createTemp('viewer-failure-');
    try {
      final destination = Directory('${directory.path}/occupied');
      await destination.create();
      await expectLater(
          writeViewerFileAtomically(File(destination.path), [1, 2]),
          throwsA(isA<FileSystemException>()));
      expect(await destination.exists(), isTrue);
      expect(await directory.list().length, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
