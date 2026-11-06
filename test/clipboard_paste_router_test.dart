import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/utils/clipboard_paste_router.dart';

void main() {
  test('file takes precedence when clipboard also offers text URI', () async {
    var textReads = 0, attached = '', inserted = '';
    await routeClipboardPaste<String>(
        isCurrent: () => true,
        readFile: () async => 'image-bytes',
        readText: () async {
          textReads++;
          return 'content://file';
        },
        attachFile: (value) async {
          attached = value;
        },
        insertText: (value) {
          inserted = value;
        },
        onEmpty: () {});
    expect(attached, 'image-bytes');
    expect(textReads, 0);
    expect(inserted, isEmpty);
  });
  test('plain external text remains pasteable', () async {
    var inserted = '';
    await routeClipboardPaste<String>(
        isCurrent: () => true,
        readFile: () async => null,
        readText: () async => 'ordinary text',
        attachFile: (_) async {},
        insertText: (value) {
          inserted = value;
        },
        onEmpty: () {});
    expect(inserted, 'ordinary text');
  });
  test('account or target change during file read cancels insertion', () async {
    var current = true, attached = false, textRead = false;
    final gate = Completer<String?>();
    final result = routeClipboardPaste<String>(
        isCurrent: () => current,
        readFile: () => gate.future,
        readText: () async {
          textRead = true;
          return null;
        },
        attachFile: (_) async {
          attached = true;
        },
        insertText: (_) {},
        onEmpty: () {});
    current = false;
    gate.complete('file');
    await result;
    expect(attached, isFalse);
    expect(textRead, isFalse);
  });
  test('account or target change during text read cancels insertion', () async {
    var current = true, inserted = false;
    final gate = Completer<String?>();
    final result = routeClipboardPaste<String>(
        isCurrent: () => current,
        readFile: () async => null,
        readText: () => gate.future,
        attachFile: (_) async {},
        insertText: (_) {
          inserted = true;
        },
        onEmpty: () {});
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete('text');
    await result;
    expect(inserted, isFalse);
  });
  test('empty clipboard notifies only when target remains current', () async {
    var notified = false;
    await routeClipboardPaste<String>(
        isCurrent: () => true,
        readFile: () async => null,
        readText: () async => null,
        attachFile: (_) async {},
        insertText: (_) {},
        onEmpty: () {
          notified = true;
        });
    expect(notified, isTrue);
  });
}
