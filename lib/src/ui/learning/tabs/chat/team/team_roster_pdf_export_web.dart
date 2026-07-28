import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> exportRosterPdfBytes({
  required Uint8List bytes,
  required String filename,
  required String subject,
}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(
          bytes,
          mimeType: 'application/pdf',
          name: filename,
        ),
      ],
      subject: subject,
      text: 'Список группы для отметок',
    ),
  );
}
