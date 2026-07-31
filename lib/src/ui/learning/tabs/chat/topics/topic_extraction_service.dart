import 'dart:typed_data';

import 'topic_list_models.dart';
import 'topic_list_parser.dart';
import 'topic_pdf_page_renderer.dart' show TopicPdfPageRenderer;

/// Interface for extracting topic drafts from documents/photos.
///
/// Current implementation is local/deterministic (OCR + parsers).
/// AI cleanup / structure recognition can plug in later without UI rewrites.
abstract class TopicExtractionService {
  Future<TopicParseResult> extractFromBytes({
    required Uint8List bytes,
    required String sourceName,
    TopicOcrAdapter? ocr,
  });

  Future<TopicParseResult> extractFromPath({
    required String path,
    TopicOcrAdapter? ocr,
  });
}

/// Deterministic on-device extraction via [TopicListParser].
class LocalTopicExtractionService implements TopicExtractionService {
  LocalTopicExtractionService({
    TopicListParser? parser,
    TopicOcrAdapter? ocrAdapter,
    TopicPdfPageRenderer? pdfPageRenderer,
  }) : _parser = parser ??
            TopicListParser(
              ocrAdapter: ocrAdapter,
              pdfPageRenderer: pdfPageRenderer,
            );

  final TopicListParser _parser;

  @override
  Future<TopicParseResult> extractFromBytes({
    required Uint8List bytes,
    required String sourceName,
    TopicOcrAdapter? ocr,
  }) {
    return _parser.parseBytes(
      bytes: bytes,
      sourceName: sourceName,
      ocr: ocr,
    );
  }

  @override
  Future<TopicParseResult> extractFromPath({
    required String path,
    TopicOcrAdapter? ocr,
  }) {
    return _parser.parseFile(path: path, ocr: ocr);
  }
}
