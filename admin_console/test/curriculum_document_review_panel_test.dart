import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/curriculum_document_review_panel.dart';
import 'package:student_platform_admin/features/import_studio/curriculum_plan_import_repository.dart';

void main() {
  testWidgets('shows ambiguous draft and a disabled continue action', (
    tester,
  ) async {
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.textPdf,
      fileName: 'plan.pdf',
      fileSize: 1000,
      localSha256: List.filled(64, 'a').join(),
      pageCount: 2,
      metadata: const CurriculumDraftMetadata(
        directionCode: '08.03.01',
        directionName: 'Строительство',
        profileName: 'Промышленное и гражданское строительство',
        qualification: 'бакалавр',
        studyForm: AcademicStudyForm.fullTime,
        admissionYear: 2025,
        nominalSemesters: 8,
      ),
      rows: const [
        CurriculumDraftRow(
          candidateKey: 'candidate-1',
          subjectIndex: 'Б1.О.01',
          subjectName: 'Физическая культура и спорт',
          sourcePage: 1,
          sourceRegion: AcademicSourceRegion(
            left: 1,
            top: 10,
            right: 100,
            bottom: 1,
          ),
          blockingIssues: ['semester_required', 'review_confirmation_required'],
        ),
      ],
      warnings: const ['SHA-256 вычислен локально; сервером не подтверждён.'],
    );

    await tester.pumpWidget(_app(draft));

    expect(find.textContaining('PDF с текстом'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(
      find.textContaining('требуют проверки 1', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Проверено'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Проверить на сервере'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('manual-required is not shown as successful zero rows', (
    tester,
  ) async {
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.manualRequired,
      fileName: 'scan.pdf',
      fileSize: 1000,
      localSha256: List.filled(64, 'b').join(),
      pageCount: 1,
      metadata: const CurriculumDraftMetadata(),
      rows: const [],
      blockingIssues: const [
        'В PDF нет доступного текстового слоя.',
        'OCR в Web Admin пока недоступен.',
      ],
    );

    await tester.pumpWidget(_app(draft));

    expect(find.textContaining('Нужен ручной ввод'), findsOneWidget);
    expect(find.textContaining('Продолжение невозможно'), findsOneWidget);
    expect(find.text('Кандидаты дисциплин'), findsNothing);
  });

  testWidgets('editing a confirmed row resets confirmation', (tester) async {
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.xlsx,
      fileName: 'plan.xlsx',
      fileSize: 1000,
      localSha256: List.filled(64, 'c').join(),
      pageCount: 0,
      metadata: const CurriculumDraftMetadata(),
      rows: const [
        CurriculumDraftRow(
          candidateKey: 'candidate-edit',
          subjectIndex: 'Б1.О.01',
          subjectName: 'Математика',
          occurrences: [
            CurriculumDraftOccurrence(
              semesterNumber: 1,
              sourcePage: 1,
              sourceRegion: null,
            ),
          ],
          sourcePage: 1,
          sourceRegion: null,
          blockingIssues: ['review_confirmation_required'],
        ),
      ],
    );

    await tester.pumpWidget(_app(draft));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();

    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isTrue);
    expect(
      find.textContaining('требуют проверки 0', skipOffstage: false),
      findsOneWidget,
    );

    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Дисциплина',
      skipOffstage: false,
    );
    await tester.enterText(nameField, 'Высшая математика');
    await tester.pump();

    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isFalse);
    expect(
      find.textContaining('требуют проверки 1', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('confirmation cannot clear an unresolved source control', (
    tester,
  ) async {
    var emittedRows = <CurriculumDraftRow>[];
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.textPdf,
      fileName: 'plan.pdf',
      fileSize: 1000,
      localSha256: List.filled(64, 'e').join(),
      pageCount: 2,
      metadata: const CurriculumDraftMetadata(),
      rows: const [
        CurriculumDraftRow(
          candidateKey: 'candidate-unresolved-control',
          subjectIndex: 'Б1.О.01',
          subjectName: 'Математика',
          occurrences: [
            CurriculumDraftOccurrence(
              semesterNumber: 1,
              sourcePage: 2,
              sourceRegion: null,
            ),
          ],
          unresolvedAssessments: [
            CurriculumDraftAssessment(
              type: CurriculumAssessmentType.exam,
              semesterNumber: null,
              rawValue: 'X',
              sourcePage: 2,
              sourceRegion: null,
            ),
          ],
          sourcePage: 2,
          sourceRegion: null,
          blockingIssues: [
            'assessment_semester_unresolved:exam:X',
            'duplicate_assessment:exam:1',
            'review_confirmation_required',
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      _app(draft, onRowsChanged: (rows) => emittedRows = rows),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    tester.widget<Checkbox>(find.byType(Checkbox).last).onChanged!(true);
    await tester.pump();

    expect(
      emittedRows.single.blockingIssues,
      contains('assessment_semester_unresolved:exam:X'),
    );
    expect(
      emittedRows.single.blockingIssues,
      contains('duplicate_assessment:exam:1'),
    );
    expect(emittedRows.single.requiresReview, isTrue);
    expect(find.textContaining('семестр «X» не распознан'), findsOneWidget);
    expect(
      find.textContaining('Повторная форма контроля: Экзамен, семестр 1'),
      findsOneWidget,
    );
  });

  testWidgets('aggregate row supports occurrence, heading and exclusion', (
    tester,
  ) async {
    var emittedRows = <CurriculumDraftRow>[];
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.textPdf,
      fileName: 'plan.pdf',
      fileSize: 1000,
      localSha256: List.filled(64, 'd').join(),
      pageCount: 1,
      metadata: const CurriculumDraftMetadata(),
      rows: const [
        CurriculumDraftRow(
          candidateKey: 'candidate-aggregate',
          subjectIndex: 'Б1.В.ДВ.02',
          subjectName: 'Элективные дисциплины',
          hoursTotal: 108,
          credits: 3,
          occurrences: [
            CurriculumDraftOccurrence(
              semesterNumber: 7,
              sourcePage: 1,
              sourceRegion: null,
              assessments: [
                CurriculumDraftAssessment(
                  type: CurriculumAssessmentType.credit,
                  semesterNumber: 7,
                  rawValue: '7',
                  sourcePage: 1,
                  sourceRegion: null,
                ),
              ],
            ),
          ],
          sourcePage: 1,
          sourceRegion: null,
          disposition: CurriculumRowDisposition.occurrence,
          isAggregateCandidate: true,
          blockingIssues: ['review_confirmation_required'],
        ),
      ],
    );

    await tester.pumpWidget(
      _app(draft, onRowsChanged: (rows) => emittedRows = rows),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();

    Future<void> selectDisposition(String label) async {
      final field = find.byType(
        DropdownButtonFormField<CurriculumRowDisposition>,
        skipOffstage: false,
      );
      await tester.ensureVisible(field);
      await tester.pump();
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await selectDisposition('Заголовок блока');
    expect(emittedRows.single.occurrences.single.semesterNumber, 7);
    expect(emittedRows.single.hoursTotal, 108);
    expect(emittedRows.single.credits, 3);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(
      find.textContaining('требуют проверки 0', skipOffstage: false),
      findsOneWidget,
    );

    await selectDisposition('Не импортировать');
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isFalse);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(
      find.textContaining('требуют проверки 0', skipOffstage: false),
      findsOneWidget,
    );

    await selectDisposition('Дисциплина плана');
    expect(
      find.textContaining('требуют проверки 1', skipOffstage: false),
      findsOneWidget,
    );
    expect(emittedRows.single.occurrences.single.semesterNumber, 7);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'Зачёт'))
          .selected,
      isTrue,
    );
    tester.widget<Checkbox>(find.byType(Checkbox).last).onChanged!(true);
    await tester.pump();
    expect(
      find.textContaining('требуют проверки 0', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets(
    'semester workload controls and unresolved assessments are editable',
    (tester) async {
      var emittedRows = <CurriculumDraftRow>[];
      final draft = AcademicDocumentDraft(
        diagnosis: AcademicDocumentDiagnosis.textPdf,
        fileName: 'plan.pdf',
        fileSize: 1000,
        localSha256: List.filled(64, 'e').join(),
        pageCount: 1,
        metadata: const CurriculumDraftMetadata(nominalSemesters: 10),
        rows: const [
          CurriculumDraftRow(
            candidateKey: 'editable-nested',
            subjectIndex: 'Б1.О.09',
            subjectName: 'Математика',
            hoursTotal: 216,
            credits: 6,
            sourcePage: 1,
            sourceRegion: null,
            blockingIssues: ['assessment_semester_unresolved:credit:X'],
            occurrences: [
              CurriculumDraftOccurrence(
                semesterNumber: 1,
                sourcePage: 1,
                sourceRegion: null,
                workload: {'lecture_hours': 36},
              ),
            ],
            unresolvedAssessments: [
              CurriculumDraftAssessment(
                type: CurriculumAssessmentType.credit,
                semesterNumber: null,
                rawValue: 'X',
                sourcePage: 1,
                sourceRegion: null,
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        _app(draft, onRowsChanged: (rows) => emittedRows = rows),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();

      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const ValueKey('semester:1')),
          )
          .onChanged!(2);
      await tester.pump();
      expect(emittedRows.single.occurrences.single.semesterNumber, 2);

      await tester.enterText(
        find.byKey(const ValueKey('workload:2:lecture_hours')),
        '42',
      );
      await tester.pump();
      expect(
        emittedRows.single.occurrences.single.workload['lecture_hours'],
        42,
      );

      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, 'Курсовая работа'),
          )
          .onSelected!(true);
      await tester.pump();
      expect(
        emittedRows.single.occurrences.single.assessments.map(
          (value) => value.type,
        ),
        contains(CurriculumAssessmentType.courseWork),
      );

      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const ValueKey('resolve:editable-nested:0')),
          )
          .onChanged!(2);
      await tester.pump();
      expect(emittedRows.single.unresolvedAssessments, isEmpty);
      expect(
        emittedRows.single.occurrences.single.assessments.map(
          (value) => value.type,
        ),
        contains(CurriculumAssessmentType.credit),
      );

      tester.widget<Checkbox>(find.byType(Checkbox).last).onChanged!(true);
      await tester.pump();
      expect(emittedRows.single.requiresReview, isFalse);
    },
  );

  testWidgets('study-form edit discards an obsolete dry-run response', (
    tester,
  ) async {
    final repository = _DelayedImportRepository();
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.textPdf,
      fileName: 'plan.pdf',
      fileSize: 1000,
      localSha256: List.filled(64, 'a').join(),
      pageCount: 1,
      metadata: const CurriculumDraftMetadata(
        directionCode: '08.03.01',
        directionName: 'Строительство',
        profileName: 'ПГС',
        qualification: 'бакалавр',
        studyForm: AcademicStudyForm.fullTime,
        admissionYear: 2025,
        nominalSemesters: 8,
        planCode: 'ПГС-2025',
      ),
      rows: const [
        CurriculumDraftRow(
          candidateKey: 'stale-preview',
          subjectIndex: 'Б1.О.09',
          subjectName: 'Математика',
          sourcePage: 1,
          sourceRegion: null,
          reviewerConfirmed: true,
          occurrences: [
            CurriculumDraftOccurrence(
              semesterNumber: 1,
              sourcePage: 1,
              sourceRegion: null,
              reviewerConfirmed: true,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_app(draft, importRepository: repository));

    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Проверить на сервере'),
        )
        .onPressed!();
    await tester.pump();
    tester
        .widget<DropdownButtonFormField<AcademicStudyForm>>(
          find.byType(DropdownButtonFormField<AcademicStudyForm>),
        )
        .onChanged!(AcademicStudyForm.extramural);
    await tester.pump();

    repository.completeDryRun();
    await tester.pumpAndSettle();

    expect(find.text('Проверка пройдена'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Сохранить план'), findsNothing);
  });

  testWidgets('reviewed draft runs server preview before explicit apply', (
    tester,
  ) async {
    final repository = _RecordingImportRepository();
    final draft = AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.textPdf,
      fileName: 'plan.pdf',
      fileSize: 1000,
      localSha256: List.filled(64, 'f').join(),
      pageCount: 2,
      metadata: const CurriculumDraftMetadata(
        directionCode: '08.03.01',
        directionName: 'Строительство',
        profileName: 'ПГС',
        qualification: 'бакалавр',
        studyForm: AcademicStudyForm.fullTime,
        admissionYear: 2025,
        nominalSemesters: 8,
        planCode: 'ПГС-2025',
      ),
      rows: const [
        CurriculumDraftRow(
          candidateKey: 'candidate-ready',
          subjectIndex: 'Б1.О.09',
          subjectName: 'Математика',
          hoursTotal: 216,
          credits: 6,
          sourcePage: 1,
          sourceRegion: null,
          reviewerConfirmed: true,
          occurrences: [
            CurriculumDraftOccurrence(
              semesterNumber: 1,
              sourcePage: 1,
              sourceRegion: null,
              reviewerConfirmed: true,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_app(draft, importRepository: repository));

    final previewButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Проверить на сервере'),
    );
    expect(previewButton.onPressed, isNotNull);
    previewButton.onPressed!();
    await tester.pumpAndSettle();

    expect(repository.dryRuns, 1);
    expect(find.text('Проверка пройдена'), findsOneWidget);
    final applyButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Сохранить план'),
    );
    applyButton.onPressed!();
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Код плана'),
      'ПГС-2025',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();

    expect(repository.applies, 1);
    expect(find.textContaining('Учебный план сохранён'), findsOneWidget);
  });
}

Widget _app(
  AcademicDocumentDraft draft, {
  ValueChanged<List<CurriculumDraftRow>>? onRowsChanged,
  CurriculumPlanImportRepository? importRepository,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 850,
        child: CurriculumDocumentReviewPanel(
          initialDraft: draft,
          importRepository:
              importRepository ?? LocalCurriculumPlanImportRepository(),
          onRowsChanged: onRowsChanged,
        ),
      ),
    ),
  );
}

class _RecordingImportRepository implements CurriculumPlanImportRepository {
  int dryRuns = 0;
  int applies = 0;

  @override
  Future<List<CurriculumSubjectReference>> listSubjects() async => const [];

  @override
  Future<CurriculumPlanTarget> ensureDraftTarget({
    required CurriculumDraftMetadata metadata,
    required String versionLabel,
    required AcademicDocumentDraft source,
  }) async {
    return const CurriculumPlanTarget(
      programId: 'program-1',
      planId: 'plan-1',
      planCode: 'ПГС-2025',
      planRowVersion: 1,
    );
  }

  @override
  Future<CurriculumPlanDryRunResult> dryRun({
    required CurriculumPlanTarget target,
    required AcademicDocumentDraft source,
    required List<CurriculumDraftRow> rows,
  }) async {
    dryRuns++;
    return const CurriculumPlanDryRunResult(
      ok: true,
      applyEnabled: true,
      previewId: 'preview-1',
      summary: {'new': 1, 'update': 0, 'unchanged': 0, 'error': 0},
      items: [],
    );
  }

  @override
  Future<CurriculumPlanApplyResult> apply({
    required String previewId,
    required String confirmPlanCode,
  }) async {
    applies++;
    return const CurriculumPlanApplyResult(
      ok: true,
      replayed: false,
      summary: {'inserted': 1, 'updated': 0, 'unchanged': 0},
    );
  }
}

class _DelayedImportRepository extends _RecordingImportRepository {
  final _dryRunCompleter = Completer<CurriculumPlanDryRunResult>();

  void completeDryRun() {
    _dryRunCompleter.complete(
      const CurriculumPlanDryRunResult(
        ok: true,
        applyEnabled: true,
        previewId: 'obsolete-preview',
        summary: {'inserted': 1, 'updated': 0, 'unchanged': 0, 'blocked': 0},
        items: [],
      ),
    );
  }

  @override
  Future<CurriculumPlanDryRunResult> dryRun({
    required CurriculumPlanTarget target,
    required AcademicDocumentDraft source,
    required List<CurriculumDraftRow> rows,
  }) {
    dryRuns++;
    return _dryRunCompleter.future;
  }
}
