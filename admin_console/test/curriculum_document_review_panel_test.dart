import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/curriculum_document_review_panel.dart';

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
    expect(find.textContaining('требуют проверки 1'), findsOneWidget);
    expect(find.text('Проверено'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Продолжить к dry-run'),
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
          semesterNumber: 1,
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
    expect(find.textContaining('требуют проверки 0'), findsOneWidget);

    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Дисциплина',
    );
    await tester.enterText(nameField, 'Высшая математика');
    await tester.pump();

    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isFalse);
    expect(find.textContaining('требуют проверки 1'), findsOneWidget);
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
          semesterNumber: 7,
          hoursTotal: 108,
          credits: 3,
          controlForm: 'зачёт',
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
      await tester.tap(
        find.byType(DropdownButtonFormField<CurriculumRowDisposition>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await selectDisposition('Заголовок блока');
    expect(emittedRows.single.semesterNumber, isNull);
    expect(emittedRows.single.hoursTotal, isNull);
    expect(emittedRows.single.credits, isNull);
    expect(emittedRows.single.controlForm, isNull);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(find.textContaining('требуют проверки 0'), findsOneWidget);

    await selectDisposition('Не импортировать');
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isFalse);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(find.textContaining('требуют проверки 0'), findsOneWidget);

    await selectDisposition('Дисциплина плана');
    expect(find.textContaining('требуют проверки 1'), findsOneWidget);
    final semesterField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Семестр',
    );
    await tester.enterText(semesterField, '7');
    await tester.pump();
    expect(emittedRows.single.semesterNumber, 7);
    await tester.enterText(semesterField, '');
    await tester.pump();
    expect(emittedRows.single.semesterNumber, isNull);
    expect(find.textContaining('требуют проверки 1'), findsOneWidget);
    await tester.enterText(semesterField, '7');
    await tester.pump();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(find.textContaining('требуют проверки 0'), findsOneWidget);
  });
}

Widget _app(
  AcademicDocumentDraft draft, {
  ValueChanged<List<CurriculumDraftRow>>? onRowsChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 850,
        child: CurriculumDocumentReviewPanel(
          initialDraft: draft,
          onRowsChanged: onRowsChanged,
        ),
      ),
    ),
  );
}
