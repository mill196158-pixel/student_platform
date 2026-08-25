import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_process_calendar_models.dart';
import 'package:student_platform_admin/features/import_studio/academic_process_calendar_repository.dart';
import 'package:student_platform_admin/features/import_studio/academic_process_calendar_review_panel.dart';

void main() {
  testWidgets('manual calendar rows reach apply-disabled dry-run', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 850,
            child: AcademicProcessCalendarReviewPanel(
              repository: LocalAcademicProcessCalendarRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('График учебного процесса'), findsWidgets);
    expect(find.textContaining('OCR в Web'), findsOneWidget);
    expect(find.textContaining('СбПГС'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Начало ГГГГ-ММ-ДД'),
      '2026-09-01',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Конец ГГГГ-ММ-ДД'),
      '2026-12-20',
    );
    await tester.tap(find.text('Проверить dry-run'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dry-run прошёл: 1 периодов'), findsOneWidget);
    expect(find.textContaining('Apply и публикация отключены'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Ключ 1'), 'changed');
    await tester.pump();
    expect(find.textContaining('Dry-run прошёл'), findsNothing);
  });

  testWidgets('invalid dates are stopped before repository dry-run', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 850,
            child: AcademicProcessCalendarReviewPanel(
              repository: LocalAcademicProcessCalendarRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Проверить dry-run'));
    await tester.pump();

    expect(find.textContaining('Введите даты ГГГГ-ММ-ДД'), findsOneWidget);
  });

  testWidgets('retry after failed dry-run reuses committed draft version', (
    tester,
  ) async {
    final repository = _RetryRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 850,
            child: AcademicProcessCalendarReviewPanel(repository: repository),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Начало ГГГГ-ММ-ДД'),
      '2026-09-01',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Конец ГГГГ-ММ-ДД'),
      '2026-12-20',
    );

    await tester.tap(find.text('Проверить dry-run'));
    await tester.pumpAndSettle();
    expect(repository.createCalls, 1);
    expect(repository.dryRunCalls, 1);

    await tester.tap(find.text('Проверить dry-run'));
    await tester.pumpAndSettle();

    expect(repository.createCalls, 1);
    expect(repository.dryRunCalls, 2);
    expect(find.textContaining('Dry-run прошёл'), findsOneWidget);
  });

  testWidgets('editors are disabled while draft dry-run is in flight', (
    tester,
  ) async {
    final repository = _BlockingRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 850,
            child: AcademicProcessCalendarReviewPanel(repository: repository),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    final startsFinder = find.widgetWithText(TextField, 'Начало ГГГГ-ММ-ДД');
    final endsFinder = find.widgetWithText(TextField, 'Конец ГГГГ-ММ-ДД');
    await tester.enterText(startsFinder, '2026-09-01');
    await tester.enterText(endsFinder, '2026-12-20');

    await tester.tap(find.text('Проверить dry-run'));
    await tester.pump();

    expect(tester.widget<TextField>(startsFinder).enabled, isFalse);
    expect(tester.widget<TextField>(endsFinder).enabled, isFalse);
    expect(find.text('Добавить период'), findsOneWidget);
    final addButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Добавить период'),
    );
    expect(addButton.onPressed, isNull);

    repository.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(startsFinder).enabled, isTrue);
  });
}

class _RetryRepository implements AcademicProcessCalendarRepository {
  final _delegate = LocalAcademicProcessCalendarRepository();
  int createCalls = 0;
  int dryRunCalls = 0;

  @override
  Future<AcademicProcessCalendarReferences> loadReferences() {
    return _delegate.loadReferences();
  }

  @override
  Future<String> createDraftVersion({
    required String academicYearId,
    required AcademicProcessAudienceKind audienceKind,
    String? audienceId,
    required String title,
    required String versionLabel,
    String? sourceFileName,
    String? sourceMimeType,
    String? localSha256,
  }) async {
    createCalls++;
    return 'stable-version';
  }

  @override
  Future<AcademicProcessDryRunResult> dryRun({
    required String versionId,
    required List<AcademicProcessPeriodDraft> rows,
  }) {
    dryRunCalls++;
    if (dryRunCalls == 1) {
      throw StateError('transient_failure');
    }
    return _delegate.dryRun(versionId: versionId, rows: rows);
  }
}

class _BlockingRepository implements AcademicProcessCalendarRepository {
  final _delegate = LocalAcademicProcessCalendarRepository();
  final _completer = Completer<AcademicProcessDryRunResult>();

  @override
  Future<AcademicProcessCalendarReferences> loadReferences() {
    return _delegate.loadReferences();
  }

  @override
  Future<String> createDraftVersion({
    required String academicYearId,
    required AcademicProcessAudienceKind audienceKind,
    String? audienceId,
    required String title,
    required String versionLabel,
    String? sourceFileName,
    String? sourceMimeType,
    String? localSha256,
  }) async {
    return 'blocking-version';
  }

  @override
  Future<AcademicProcessDryRunResult> dryRun({
    required String versionId,
    required List<AcademicProcessPeriodDraft> rows,
  }) {
    return _completer.future;
  }

  void complete() {
    _delegate
        .dryRun(
          versionId: 'blocking-version',
          rows: [
            AcademicProcessPeriodDraft(
              periodKey: 'period-1',
              type: AcademicProcessPeriodType.study,
              courseNumber: 1,
              termInYear: 1,
              startsOn: DateTime(2026, 9, 1),
              endsOn: DateTime(2026, 12, 20),
            ),
          ],
        )
        .then(_completer.complete);
  }
}
