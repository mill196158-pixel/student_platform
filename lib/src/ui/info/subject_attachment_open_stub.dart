import 'dart:typed_data';

Future<void> openSubjectAttachmentBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required String? signedUrl,
}) async {
  throw UnsupportedError('Attachment open is not supported on this platform');
}
