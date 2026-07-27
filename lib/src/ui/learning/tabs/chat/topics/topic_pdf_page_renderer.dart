import 'dart:typed_data';

import 'topic_list_models.dart';

/// Renders PDF pages to raster images for scanned-PDF OCR.
abstract class TopicPdfPageRenderer {
  const TopicPdfPageRenderer();

  Future<int> pageCount(Uint8List pdfBytes);

  Future<Uint8List> renderPage({
    required Uint8List pdfBytes,
    required int pageIndex,
    double dpi = topicListOcrRenderDpi,
  });
}

/// Unavailable renderer for tests or platforms without PDF rasterization.
class UnavailableTopicPdfPageRenderer extends TopicPdfPageRenderer {
  const UnavailableTopicPdfPageRenderer();

  @override
  Future<int> pageCount(Uint8List pdfBytes) async {
    throw UnsupportedError('Рендер PDF недоступен на этой платформе.');
  }

  @override
  Future<Uint8List> renderPage({
    required Uint8List pdfBytes,
    required int pageIndex,
    double dpi = topicListOcrRenderDpi,
  }) async {
    throw UnsupportedError('Рендер PDF недоступен на этой платформе.');
  }
}
