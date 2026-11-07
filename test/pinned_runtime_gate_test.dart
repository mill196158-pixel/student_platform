import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/chat_file_access.dart';

Future<bool> rejectedBeforeGuard() async {
  try {
    await ChatFileAccess.resolve('https://studentsplatform.storage.yandexcloud.net/chats/test/file.png');
    return false;
  } on StateError catch (error) {
    return error.message == 'Media protection is not initialized';
  }
}

void main() {
  test('every isolate rejects private access before guard initialization', () async {
    expect(await rejectedBeforeGuard(), isTrue);
    expect(await Isolate.run(rejectedBeforeGuard), isTrue);
    expect(await Isolate.run(rejectedBeforeGuard), isTrue);
  }, skip: !const bool.fromEnvironment('PINNED_MEDIA_RUNTIME'));
}
