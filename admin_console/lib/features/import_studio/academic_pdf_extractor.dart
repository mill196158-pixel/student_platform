import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import 'academic_document_draft.dart';

abstract class AcademicPdfExtractor {
  Future<AcademicPdfExtraction> extract({
    required Uint8List bytes,
    required String fileName,
  });
}

class PdfrxAcademicPdfExtractor implements AcademicPdfExtractor {
  const PdfrxAcademicPdfExtractor();

  @override
  Future<AcademicPdfExtraction> extract({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (bytes.lengthInBytes > academicDocumentMaxBytes) {
      throw const FormatException(
        'Файл больше 20 МБ. Выберите уменьшенную копию.',
      );
    }

    await pdfrxFlutterInitialize();
    PdfDocument? document;
    try {
      document = await PdfDocument.openData(
        bytes,
        sourceName: 'academic-intake:$fileName:${bytes.lengthInBytes}',
      );
      if (document.pages.length > academicDocumentMaxPages) {
        throw const FormatException(
          'В PDF больше 500 страниц. Разделите документ на части.',
        );
      }

      final pages = <AcademicTextPage>[];
      for (final originalPage in document.pages) {
        final page = await originalPage.ensureLoaded();
        final text = await page.loadStructuredText();
        pages.add(
          AcademicTextPage(
            page: page.pageNumber,
            width: page.width,
            height: page.height,
            fullText: text.fullText,
            fragments: text.fragments
                .map((fragment) {
                  final bounds = fragment.bounds;
                  return AcademicTextFragment(
                    page: page.pageNumber,
                    text: fragment.text,
                    region: AcademicSourceRegion(
                      left: bounds.left,
                      top: bounds.top,
                      right: bounds.right,
                      bottom: bounds.bottom,
                    ),
                  );
                })
                .toList(growable: false),
          ),
        );
      }
      return AcademicPdfExtraction(pages: pages);
    } finally {
      await document?.dispose();
    }
  }
}

class AcademicPdfExtraction {
  const AcademicPdfExtraction({required this.pages});

  final List<AcademicTextPage> pages;

  int get characterCount =>
      pages.fold(0, (sum, page) => sum + page.fullText.trim().length);
}
