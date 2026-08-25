@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_intake_service.dart';

void main() {
  test('compiled Web opens supplied PGS PDF with local WASM assets', () async {
    const url = String.fromEnvironment('REAL_ACADEMIC_PDF_URL');
    const wasmUrl = String.fromEnvironment('PDFIUM_WASM_URL');
    if (url.isEmpty || wasmUrl.isEmpty) {
      markTestSkipped(
        'Set REAL_ACADEMIC_PDF_URL and PDFIUM_WASM_URL to run this smoke.',
      );
      return;
    }

    Pdfrx.pdfiumWasmModulesUrl = wasmUrl;
    final response = await http.get(Uri.parse(url));
    expect(response.statusCode, 200);
    final draft = await AcademicDocumentIntakeService().read(
      bytes: Uint8List.fromList(response.bodyBytes),
      fileName: 'up_08.03.01_pgs_2025.pdf',
    );

    expect(draft.diagnosis, AcademicDocumentDiagnosis.textPdf);
    expect(draft.pageCount, 2);
    expect(draft.metadata.directionCode, '08.03.01');
    expect(draft.metadata.studyForm, AcademicStudyForm.fullTime);
    expect(draft.metadata.admissionYear, 2025);
    expect(draft.rows.length, greaterThanOrEqualTo(40));
    expect(draft.unresolvedRowCount, draft.rows.length);
    expect(draft.canContinue, isFalse);
  });
}
