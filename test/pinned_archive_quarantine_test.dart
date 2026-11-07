import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/pinned_archive_quarantine.dart';

void main() {
  test('quarantine is durable, one-way and shared across instances', () async {
    final root = await Directory.systemTemp.createTemp('pinned-quarantine-test-');
    final first = PinnedArchiveQuarantine(root), second = PinnedArchiveQuarantine(root);
    expect(await first.isDisabled(), isFalse);
    expect(await first.trip(), isTrue);
    expect(await second.isDisabled(), isTrue);
    expect(await second.trip(), isTrue);
    final marker = File('${root.path}/pinned-archive-disabled-v1');
    await marker.writeAsString('corrupt');
    expect(await first.isDisabled(), isTrue);
    expect(await first.trip(), isFalse);
    await root.delete(recursive: true);
    expect(await first.isDisabled(), isTrue);
    expect(await first.trip(), isFalse);
  });
}
