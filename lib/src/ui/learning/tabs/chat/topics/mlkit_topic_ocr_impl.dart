import 'dart:typed_data';

import 'topic_list_parser.dart';

/// Historical ML Kit adapter name retained for tests/imports.
///
/// Stage 13.9 ships platform-channel OCR instead (see
/// [createTesseractTopicOcrAdapter]) so iOS can stay on deployment target 15
/// and build for Apple Silicon simulators.
class MlKitTopicOcrAdapter extends TopicOcrAdapter {
  const MlKitTopicOcrAdapter();

  @override
  Future<String> recognize(Uint8List bytes) {
    throw UnsupportedError(
      'ML Kit OCR заменён локальным platform OCR (Android Tesseract / iOS Vision).',
    );
  }
}

TopicOcrAdapter createMlKitTopicOcrAdapter() {
  return const UnavailableTopicOcrAdapter();
}
