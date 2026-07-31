import 'dart:typed_data';

import 'topic_list_parser.dart';

/// Stub ML Kit implementation for platforms without native OCR bindings.
class MlKitTopicOcrAdapter extends TopicOcrAdapter {
  const MlKitTopicOcrAdapter();

  @override
  Future<String> recognize(Uint8List bytes) {
    throw UnsupportedError(
      'Распознавание текста с изображения недоступно на этой платформе.',
    );
  }
}

TopicOcrAdapter createMlKitTopicOcrAdapter() {
  return const MlKitTopicOcrAdapter();
}
