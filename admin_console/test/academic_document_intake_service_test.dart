import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_intake_service.dart';
import 'package:student_platform_admin/features/import_studio/academic_pdf_extractor.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_template_service.dart';

void main() {
  test(
    'scanned PDF is manual-required, never successful empty import',
    () async {
      final service = AcademicDocumentIntakeService(
        pdfExtractor: const _FakePdfExtractor(
          AcademicPdfExtraction(
            pages: [
              AcademicTextPage(
                page: 1,
                width: 100,
                height: 100,
                fullText: '',
                fragments: [],
              ),
            ],
          ),
        ),
      );

      final draft = await service.read(
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'scan.pdf',
      );

      expect(draft.diagnosis, AcademicDocumentDiagnosis.manualRequired);
      expect(draft.rows, isEmpty);
      expect(draft.blockingIssues, isNotEmpty);
      expect(draft.canContinue, isFalse);
    },
  );

  test('rejects oversized source before PDF adapter is called', () async {
    final extractor = _CountingPdfExtractor();
    final service = AcademicDocumentIntakeService(pdfExtractor: extractor);

    await expectLater(
      service.read(
        bytes: Uint8List(academicDocumentMaxBytes + 1),
        fileName: 'large.pdf',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(extractor.calls, 0);
  });

  test('image intake fails closed to manual review without Web OCR', () async {
    final draft = await AcademicDocumentIntakeService().read(
      bytes: Uint8List.fromList([137, 80, 78, 71]),
      fileName: 'curriculum.png',
    );

    expect(draft.diagnosis, AcademicDocumentDiagnosis.manualRequired);
    expect(draft.rows, isEmpty);
    expect(draft.blockingIssues.join(' '), contains('OCR'));
    expect(draft.canContinue, isFalse);
    expect(draft.localSha256, hasLength(64));
  });

  test('maps curriculum XLSX into the versioned editable draft', () async {
    final bytes = ImportStudioTemplateService().buildTemplateBytes(
      'curriculum',
    );
    final draft = await AcademicDocumentIntakeService().read(
      bytes: Uint8List.fromList(bytes),
      fileName: 'curriculum.xlsx',
    );

    expect(draft.diagnosis, AcademicDocumentDiagnosis.xlsx);
    expect(draft.contractVersion, curriculumDocumentContractVersion);
    expect(draft.rows, isNotEmpty);
    expect(draft.rows.first.subjectName, 'Математика');
    expect(draft.rows.first.occurrences.single.semesterNumber, 1);
    expect(draft.rows.first.hoursTotal, 144);
    expect(
      draft.rows.first.occurrences.single.assessments.single.type,
      CurriculumAssessmentType.exam,
    );
    expect(draft.rows.first.requiresReview, isTrue);
    expect(draft.canContinue, isFalse);
  });
}

class _FakePdfExtractor implements AcademicPdfExtractor {
  const _FakePdfExtractor(this.result);

  final AcademicPdfExtraction result;

  @override
  Future<AcademicPdfExtraction> extract({
    required Uint8List bytes,
    required String fileName,
  }) async {
    return result;
  }
}

class _CountingPdfExtractor implements AcademicPdfExtractor {
  int calls = 0;

  @override
  Future<AcademicPdfExtraction> extract({
    required Uint8List bytes,
    required String fileName,
  }) async {
    calls += 1;
    return const AcademicPdfExtraction(pages: []);
  }
}
