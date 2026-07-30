import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

Future<void> openSubjectAttachmentBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required String? signedUrl,
}) async {
  final dir = await getTemporaryDirectory();
  final saved = await File('${dir.path}/$fileName').writeAsBytes(bytes, flush: true);
  await OpenFilex.open(saved.path);
}
