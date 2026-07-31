import 'dart:io';

import 'tesseract_topic_ocr_impl_stub.dart'
    if (dart.library.io) 'tesseract_topic_ocr_impl.dart';
import 'topic_list_parser.dart';

/// Mobile/desktop IO factory.
///
/// Uses on-device platform OCR only:
/// * Android — Tesseract `rus+eng` (bundled tessdata, offline)
/// * iOS 16+ — Apple Vision `ru-RU`/`en-US` (runtime-gated; app stays iOS 15)
///
/// Google ML Kit was removed: its iOS pods require 15.5+ and lack arm64
/// simulator slices on current Xcode/iOS Simulator, which blocked Stage 13.9
/// native builds while the product floor remains iOS 15.
TopicOcrAdapter createDefaultTopicOcrAdapter() {
  if (Platform.isAndroid || Platform.isIOS) {
    return createTesseractTopicOcrAdapter();
  }
  return const UnavailableTopicOcrAdapter();
}
