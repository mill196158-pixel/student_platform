import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Saves generated template bytes via the platform file picker (no service_role).
Future<bool> saveImportStudioTemplateBytes({
  required List<int> bytes,
  required String fileName,
}) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Сохранить шаблон Import Studio',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
    bytes: Uint8List.fromList(bytes),
  );
  return path != null || bytes.isNotEmpty;
}
