import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/support_storage_space.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('student_platform/storage_space');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('accepts positive values and fails closed on unknown space', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 12345);
    expect(await SupportStorageSpace.availableBytes(Directory.systemTemp), 12345);
    messenger.setMockMethodCallHandler(channel, (_) async => 0);
    expect(await SupportStorageSpace.availableBytes(Directory.systemTemp), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'fail'));
    expect(await SupportStorageSpace.availableBytes(Directory.systemTemp), isNull);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await SupportStorageSpace.availableBytes(Directory.systemTemp), isNull);
  });
}
