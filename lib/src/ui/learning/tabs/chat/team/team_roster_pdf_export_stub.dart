import 'dart:typed_data';

Future<void> exportRosterPdfBytes({
  required Uint8List bytes,
  required String filename,
  required String subject,
}) async {
  throw UnsupportedError('PDF export is not supported on this platform');
}
