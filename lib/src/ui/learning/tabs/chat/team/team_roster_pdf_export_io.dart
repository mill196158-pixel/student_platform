import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> exportRosterPdfBytes({
  required Uint8List bytes,
  required String filename,
  required String subject,
}) async {
  final base = await getTemporaryDirectory();
  final dir = Directory(
    '${base.path}${Platform.pathSeparator}student_platform_exports',
  );
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes, flush: true);
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        subject: subject,
        text: 'Список группы для отметок',
      ),
    );
  } catch (e) {
    debugPrint('[TeamRosterPdf] share failed: $e');
    await OpenFilex.open(file.path);
  }
}
