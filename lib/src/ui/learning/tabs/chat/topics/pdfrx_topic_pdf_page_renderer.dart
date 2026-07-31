import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'topic_list_models.dart';
import 'topic_pdf_page_renderer.dart';

/// Renders PDF pages via pdfrx for on-device OCR fallback.
class PdfrxTopicPdfPageRenderer extends TopicPdfPageRenderer {
  const PdfrxTopicPdfPageRenderer();

  @override
  Future<int> pageCount(Uint8List pdfBytes) async {
    final doc = await PdfDocument.openData(pdfBytes);
    try {
      return doc.pages.length;
    } finally {
      await doc.dispose();
    }
  }

  @override
  Future<Uint8List> renderPage({
    required Uint8List pdfBytes,
    required int pageIndex,
    double dpi = topicListOcrRenderDpi,
  }) async {
    if (pageIndex < 0) {
      throw FormatException('Некорректный номер страницы PDF.');
    }

    final doc = await PdfDocument.openData(pdfBytes);
    try {
      if (pageIndex >= doc.pages.length) {
        throw FormatException(
          'Страница ${pageIndex + 1} отсутствует в PDF (всего ${doc.pages.length}).',
        );
      }

      final page = doc.pages[pageIndex];
      final scale = dpi / 72.0;
      final width = (page.width * scale).round().clamp(1, 4096);
      final height = (page.height * scale).round().clamp(1, 4096);

      final pdfImage = await page.render(
        width: width,
        height: height,
      );
      if (pdfImage == null) {
        throw FormatException('Не удалось отрендерить страницу PDF.');
      }

      try {
        final uiImage = await pdfImage.createImage();
        try {
          final byteData =
              await uiImage.toByteData(format: ui.ImageByteFormat.png);
          if (byteData == null) {
            throw FormatException(
                'Не удалось получить изображение страницы PDF.');
          }
          return byteData.buffer.asUint8List();
        } finally {
          uiImage.dispose();
        }
      } finally {
        pdfImage.dispose();
      }
    } finally {
      await doc.dispose();
    }
  }
}

TopicPdfPageRenderer createDefaultTopicPdfPageRenderer() {
  return const PdfrxTopicPdfPageRenderer();
}
