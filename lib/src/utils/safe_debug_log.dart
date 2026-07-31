import 'package:flutter/foundation.dart';

String maskDebugId(Object? value, {int visible = 8}) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) return '<empty>';
  final take = text.length < visible ? text.length : visible;
  return '${text.substring(0, take)}...';
}

void safeDebugLog(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}
