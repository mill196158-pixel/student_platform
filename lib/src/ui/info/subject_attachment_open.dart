import 'dart:typed_data';

import 'subject_attachment_open_stub.dart'
    if (dart.library.io) 'subject_attachment_open_io.dart'
    if (dart.library.html) 'subject_attachment_open_web.dart' as impl;

/// Opens subject attachment bytes on the current platform (IO vs Web).
Future<void> openSubjectAttachmentBytes({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required String? signedUrl,
}) {
  return impl.openSubjectAttachmentBytes(
    bytes: bytes,
    fileName: fileName,
    mimeType: mimeType,
    signedUrl: signedUrl,
  );
}
