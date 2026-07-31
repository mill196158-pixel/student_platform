import 'dart:typed_data';

import 'topic_image_preprocess_stub.dart'
    if (dart.library.io) 'topic_image_preprocess_io.dart';

export 'topic_image_preprocess_stub.dart'
    if (dart.library.io) 'topic_image_preprocess_io.dart';

/// Clockwise rotation in degrees — must be 0, 90, 180, or 270.
typedef TopicImageRotation = int;

/// Preprocesses topic-list images before OCR (rotate and optional crop).
abstract class TopicImagePreprocessor {
  const TopicImagePreprocessor();

  Future<Uint8List> rotate({
    required Uint8List bytes,
    required TopicImageRotation degrees,
  });

  Future<Uint8List?> crop({
    required Uint8List bytes,
  });
}

TopicImagePreprocessor createDefaultTopicImagePreprocessor() {
  return createTopicImagePreprocessorImpl();
}
