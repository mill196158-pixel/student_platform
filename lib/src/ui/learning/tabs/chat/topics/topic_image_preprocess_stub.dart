import 'dart:typed_data';

import 'topic_image_preprocess.dart';
import 'topic_image_rotate.dart';

TopicImagePreprocessor createTopicImagePreprocessorImpl() {
  return const _StubTopicImagePreprocessor();
}

class _StubTopicImagePreprocessor extends TopicImagePreprocessor {
  const _StubTopicImagePreprocessor();

  @override
  Future<Uint8List?> crop({required Uint8List bytes}) async => null;

  @override
  Future<Uint8List> rotate({
    required Uint8List bytes,
    required int degrees,
  }) {
    return rotateTopicImageBytes(bytes: bytes, degrees: degrees);
  }
}
