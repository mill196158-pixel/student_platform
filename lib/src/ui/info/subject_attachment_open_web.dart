import 'dart:typed_data';

import 'package:url_launcher/url_launcher.dart';

Future<void> openSubjectAttachmentBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required String? signedUrl,
}) async {
  final url = (signedUrl ?? '').trim();
  if (url.isEmpty) {
    throw StateError('signedUrl required on web');
  }
  final uri = Uri.parse(url);
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok) {
    throw StateError('launchUrl failed');
  }
}
