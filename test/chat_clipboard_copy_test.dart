import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/utils/chat_clipboard_copy.dart';

void main() {
  test('account switch during slow file read prevents OS write', () async {
    final copy = ChatClipboardCopyCoordinator(), gate = Completer<Uint8List>();
    var current = true, writes = 0;
    final pending = copy.copyFile(
        isCurrent: () => current,
        readBytes: () => gate.future,
        write: (_) async {
          writes++;
        });
    current = false;
    gate.complete(Uint8List.fromList([1, 2, 3]));
    await expectLater(pending, throwsStateError);
    expect(writes, 0);
  });
  test('revoked source during delayed read never reaches clipboard', () async {
    final copy = ChatClipboardCopyCoordinator(), gate = Completer<Uint8List>();
    var allowed = true, writes = 0;
    final pending = copy.copyFile(
        isCurrent: () => allowed,
        readBytes: () => gate.future,
        write: (_) async {
          writes++;
        });
    allowed = false;
    gate.complete(Uint8List.fromList([1]));
    await expectLater(pending, throwsStateError);
    expect(writes, 0);
  });
  test('later text copy wins over older file already writing', () async {
    final copy = ChatClipboardCopyCoordinator(),
        entered = Completer<void>(),
        release = Completer<void>();
    var clipboard = '';
    final old = copy.copyFile(
        isCurrent: () => true,
        readBytes: () async => Uint8List.fromList([1]),
        write: (_) async {
          entered.complete();
          await release.future;
          clipboard = 'file';
        });
    final rejected = expectLater(old, throwsStateError);
    await entered.future;
    final next = copy.copyText(
        isCurrent: () => true,
        write: () async {
          clipboard = 'text';
        });
    release.complete();
    await rejected;
    await next;
    expect(clipboard, 'text');
  });
  test('later file invalidates stale text queued behind write', () async {
    final copy = ChatClipboardCopyCoordinator(),
        entered = Completer<void>(),
        release = Completer<void>();
    var clipboard = '';
    final old = copy.copyText(
        isCurrent: () => true,
        write: () async {
          entered.complete();
          await release.future;
          clipboard = 'old';
        });
    final rejected = expectLater(old, throwsStateError);
    await entered.future;
    final next = copy.copyFile(
        isCurrent: () => true,
        readBytes: () async => Uint8List.fromList([1]),
        write: (_) async {
          clipboard = 'file';
        });
    release.complete();
    await rejected;
    await next;
    expect(clipboard, 'file');
  });
}
