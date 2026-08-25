import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/curriculum_plan_import_repository.dart';

void main() {
  test('flattens one source subject without multiplying aggregates', () {
    final rows = flattenCurriculumPlanRows(
      source: _draft(),
      rows: _draft().rows,
    );

    expect(rows, hasLength(2));
    expect(rows[0]['source_subject_key'], rows[1]['source_subject_key']);
    expect(
      rows[0]['source_occurrence_key'],
      isNot(rows[1]['source_occurrence_key']),
    );
    expect(rows[0]['is_aggregate_owner'], isTrue);
    expect(rows[0]['hours_total'], 216);
    expect(rows[0]['credits'], 6);
    expect(rows[1]['is_aggregate_owner'], isFalse);
    expect(rows[1]['hours_total'], isNull);
    expect(rows[1]['credits'], isNull);
    expect(rows[0]['assessment_types'], ['credit', 'exam']);
    expect(rows[1]['assessment_types'], ['course_work']);
  });

  test('refuses a draft with unresolved review markers', () {
    final draft = _draft();
    final row = draft.rows.single.copyWith(
      blockingIssues: const ['assessment_semester_unresolved'],
    );

    expect(
      () => flattenCurriculumPlanRows(source: draft, rows: [row]),
      throwsA(
        isA<CurriculumPlanImportException>().having(
          (error) => error.code,
          'code',
          'draft_not_reviewed',
        ),
      ),
    );
  });

  test('creates target then requests a server-bound preview', () async {
    final calls = <String>[];
    final rpc = _FakeRpc((function, params) {
      calls.add(function);
      switch (function) {
        case 'admin_list_educational_programs':
          return <Map<String, dynamic>>[];
        case 'admin_upsert_educational_program':
          return 'program-1';
        case 'admin_list_curriculum_plans':
          final priorCreates = calls
              .where((item) => item == 'admin_upsert_curriculum_plan')
              .length;
          return priorCreates == 0
              ? <Map<String, dynamic>>[]
              : [
                  {
                    'id': 'plan-1',
                    'educational_program_id': 'program-1',
                    'admission_year': 2025,
                    'plan_code': '08.03.01-ПГС-2025',
                    'version_label': 'draft-1',
                    'status': 'draft',
                    'row_version': 1,
                  },
                ];
        case 'admin_upsert_curriculum_plan':
          expect(
            params?['p_parser_contract_version'],
            'curriculum-document-v2',
          );
          return 'plan-1';
        case 'admin_curriculum_plan_import_dry_run_v2':
          expect(params?['p_source_reviewed'], isTrue);
          expect(params?['p_expected_row_version'], 1);
          expect(params?['p_rows'], hasLength(2));
          return {
            'ok': true,
            'apply_enabled': true,
            'preview_token': 'preview-1',
            'summary': {'new': 2, 'update': 0, 'error': 0},
            'items': <Map<String, dynamic>>[],
          };
        default:
          throw StateError('Unexpected RPC $function');
      }
    });
    final repository = SupabaseCurriculumPlanImportRepository(rpcClient: rpc);
    final draft = _draft();

    final target = await repository.ensureDraftTarget(
      metadata: draft.metadata,
      versionLabel: 'draft-1',
      source: draft,
    );
    final preview = await repository.dryRun(
      target: target,
      source: draft,
      rows: draft.rows,
    );

    expect(target.planId, 'plan-1');
    expect(preview.previewId, 'preview-1');
    expect(preview.applyEnabled, isTrue);
  });
}

AcademicDocumentDraft _draft() {
  const region = AcademicSourceRegion(
    left: 10,
    top: 20,
    right: 300,
    bottom: 40,
  );
  return AcademicDocumentDraft(
    diagnosis: AcademicDocumentDiagnosis.textPdf,
    fileName: 'plan.pdf',
    fileSize: 1000,
    localSha256: List.filled(64, 'a').join(),
    pageCount: 10,
    metadata: const CurriculumDraftMetadata(
      directionCode: '08.03.01',
      directionName: 'Строительство',
      profileName: 'Промышленное и гражданское строительство',
      qualification: 'бакалавр',
      studyForm: AcademicStudyForm.fullTime,
      admissionYear: 2025,
      nominalSemesters: 8,
      planCode: '08.03.01-ПГС-2025',
    ),
    rows: const [
      CurriculumDraftRow(
        candidateKey: 'candidate-p1-1',
        subjectIndex: 'Б1.О.09',
        subjectName: 'Математика',
        hoursTotal: 216,
        credits: 6,
        sourcePage: 1,
        sourceRegion: region,
        reviewerConfirmed: true,
        occurrences: [
          CurriculumDraftOccurrence(
            semesterNumber: 1,
            sourcePage: 1,
            sourceRegion: region,
            reviewerConfirmed: true,
            assessments: [
              CurriculumDraftAssessment(
                type: CurriculumAssessmentType.exam,
                semesterNumber: 1,
                rawValue: '1',
                sourcePage: 1,
                sourceRegion: region,
                reviewerConfirmed: true,
              ),
              CurriculumDraftAssessment(
                type: CurriculumAssessmentType.credit,
                semesterNumber: 1,
                rawValue: '1',
                sourcePage: 1,
                sourceRegion: region,
                reviewerConfirmed: true,
              ),
            ],
          ),
          CurriculumDraftOccurrence(
            semesterNumber: 2,
            sourcePage: 1,
            sourceRegion: region,
            reviewerConfirmed: true,
            assessments: [
              CurriculumDraftAssessment(
                type: CurriculumAssessmentType.courseWork,
                semesterNumber: 2,
                rawValue: '2',
                sourcePage: 1,
                sourceRegion: region,
                reviewerConfirmed: true,
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

class _FakeRpc implements CurriculumPlanImportRpcClient {
  _FakeRpc(this.handler);

  final dynamic Function(String, Map<String, dynamic>?) handler;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    return handler(function, params);
  }
}
