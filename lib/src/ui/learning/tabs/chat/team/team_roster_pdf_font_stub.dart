import 'dart:typed_data';

import 'package:flutter/services.dart';

Future<ByteData?> loadPreferredRosterFontBytes() async {
  try {
    return await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
  } catch (_) {
    return null;
  }
}
