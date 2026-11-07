import 'dart:io';
import 'package:flutter/services.dart';

/// Unknown platforms and native errors fail closed: no migration is attempted.
class SupportStorageSpace {
  static const MethodChannel _channel = MethodChannel('student_platform/storage_space');

  static Future<int?> availableBytes(Directory _) async {
    try {
      final value = await _channel.invokeMethod<int>('availableSupportBytes');
      return value != null && value > 0 ? value : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
