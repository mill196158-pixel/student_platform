import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Prefer bundled Noto Sans (Cyrillic) — system fonts are often unreadable
/// inside the iOS app sandbox, which caused □□□ on real devices.
Future<ByteData?> loadPreferredRosterFontBytes() async {
  try {
    return await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
  } catch (_) {}

  final candidates = <String>[
    if (Platform.isMacOS || Platform.isIOS)
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    if (Platform.isMacOS || Platform.isIOS)
      '/System/Library/Fonts/Supplemental/Arial.ttf',
    if (Platform.isWindows) r'C:\Windows\Fonts\arial.ttf',
    if (Platform.isWindows) r'C:\Windows\Fonts\segoeui.ttf',
    if (Platform.isAndroid) '/system/fonts/Roboto-Regular.ttf',
    if (Platform.isLinux) '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      return ByteData.sublistView(Uint8List.fromList(bytes));
    }
  }
  return null;
}
