import 'topic_list_parser.dart';

/// Stub Tesseract OCR for platforms without native bindings.
TopicOcrAdapter createTesseractTopicOcrAdapter() {
  return const UnavailableTopicOcrAdapter();
}
