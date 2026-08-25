@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_intake_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getTemporaryDirectory') {
              return Directory.systemTemp.path;
            }
            return null;
          },
        );
  });

  test('real PGS 2025 PDF opens and yields a review draft', () async {
    final path = Platform.environment['REAL_ACADEMIC_PDF'];
    if (path == null || path.trim().isEmpty) {
      markTestSkipped('Set REAL_ACADEMIC_PDF to run this smoke.');
      return;
    }
    final file = File(path);
    expect(await file.exists(), isTrue, reason: path);

    final bytes = Uint8List.fromList(await file.readAsBytes());
    final draft = await AcademicDocumentIntakeService().read(
      bytes: bytes,
      fileName: file.uri.pathSegments.last,
    );

    expect(draft.diagnosis, AcademicDocumentDiagnosis.textPdf);
    expect(draft.pageCount, 2);
    expect(
      draft.localSha256,
      '318a9169484157601cc3d765398d7b9fbaf6f3d90524fc9b6cd6f286064d18b7',
    );
    expect(draft.metadata.directionCode, '08.03.01');
    expect(draft.metadata.directionName, 'Строительство');
    expect(
      draft.metadata.profileName,
      'Промышленное и гражданское строительство',
    );
    expect(draft.metadata.qualification, 'бакалавр');
    expect(draft.metadata.studyForm, AcademicStudyForm.fullTime);
    expect(draft.metadata.admissionYear, 2025);
    expect(draft.metadata.nominalSemesters, 8);
    expect(draft.metadata.planCode, '08.03.01_2025_2_ПГС.plx');
    expect(draft.rows.length, greaterThanOrEqualTo(40));
    expect(
      draft.rows.map((row) => row.subjectIndex).toSet().length,
      draft.rows.length,
    );
    expect(draft.unresolvedRowCount, draft.rows.length);
    expect(draft.canContinue, isFalse);
  });
}
