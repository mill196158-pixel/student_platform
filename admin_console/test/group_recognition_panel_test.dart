import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_panel.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_repository.dart';

class _Repository implements GroupRecognitionRepository {
  _Repository(this.item);

  final GroupRecognitionItem item;
  int saves = 0;
  int applies = 0;

  GroupRecognitionPreview preview({
    int decisionRevision = 0,
    bool applied = false,
  }) {
    final savedDecision = decisionRevision == 0
        ? null
        : GroupRecognitionDecision(
            previewRowId: item.rowId,
            action: item.classification == 'new_candidate'
                ? GroupRecognitionDecisionAction.createGroup
                : GroupRecognitionDecisionAction.reuseGroup,
            selectedGroupId: item.candidateGroupIds.firstOrNull,
            selectedPlanId: item.candidatePlanIds.firstOrNull,
          );
    final savedItem = GroupRecognitionItem(
      rowId: item.rowId,
      sourceRowKey: item.sourceRowKey,
      rawGroupName: item.rawGroupName,
      classification: item.classification,
      parallelNumber: item.parallelNumber,
      courseNumber: item.courseNumber,
      derivedAdmissionYear: item.derivedAdmissionYear,
      candidateGroupIds: item.candidateGroupIds,
      candidatePlanIds: item.candidatePlanIds,
      candidateGroups: item.candidateGroups,
      candidatePlans: item.candidatePlans,
      decision: savedDecision,
    );
    return GroupRecognitionPreview(
      previewId: 'preview-1',
      items: [savedItem],
      summary: {'total': 1, 'needs_decision': 1, 'blocked': 0},
      applyEnabled: decisionRevision > 0,
      payloadHash: 'payload-hash',
      rowVersion: 1 + decisionRevision,
      decisionRevision: decisionRevision,
      decisionHash: 'decision-hash',
      confirmationToken: 'confirmation-token',
      results: applied
          ? const [
              GroupRecognitionApplyResult(
                action: 'create_group',
                groupName: '2-СбПГС-2',
                aliasOutcome: 'created',
                identityOutcome: 'created',
                profileOutcome: 'created',
                planLabel: 'ПГС · 2025 · 8 сем.',
              ),
            ]
          : const [],
    );
  }

  @override
  Future<List<GroupRecognitionAcademicYear>> listAcademicYears() async {
    return const [
      GroupRecognitionAcademicYear(
        id: 'year-1',
        name: '2026/2027',
        startYear: 2026,
        isCurrent: true,
      ),
    ];
  }

  @override
  Future<GroupRecognitionPreview> startPreview({
    required String academicYearId,
    required List<Map<String, dynamic>> rows,
    required String fileName,
    String? idempotencyKey,
  }) async {
    return preview();
  }

  @override
  Future<GroupRecognitionPreview> saveDecisions({
    required GroupRecognitionPreview preview,
    required List<GroupRecognitionDecision> decisions,
  }) async {
    saves++;
    return this.preview(decisionRevision: 1);
  }

  @override
  Future<GroupRecognitionPreview> apply({
    required GroupRecognitionPreview preview,
  }) async {
    applies++;
    return this.preview(decisionRevision: 1, applied: true);
  }
}

Future<void> _pump(WidgetTester tester, _Repository repository) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1100,
          height: 800,
          child: GroupRecognitionPanel(
            repository: repository,
            initialRows: const [
              {'name': '2-СбПГС-2'},
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Проверить'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('saves a durable new-group decision then applies confirmation', (
    tester,
  ) async {
    final repository = _Repository(
      const GroupRecognitionItem(
        rowId: 'row-1',
        sourceRowKey: '1',
        rawGroupName: '2-СбПГС-2',
        classification: 'new_candidate',
        parallelNumber: 2,
        courseNumber: 2,
        derivedAdmissionYear: 2025,
        candidatePlanIds: ['plan-1'],
        candidatePlans: [
          GroupRecognitionPlanCandidate(
            id: 'plan-1',
            label: '08.03.01 · ПГС · очная · приём 2025 · v1 · active · 8 сем.',
            status: 'active',
            nominalSemesters: 8,
          ),
        ],
      ),
    );
    await _pump(tester, repository);

    expect(find.text('Новая группа'), findsOneWidget);
    await tester.tap(
      find.byType(DropdownButtonFormField<GroupRecognitionDecisionAction>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать отдельную группу').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить решения'));
    await tester.pumpAndSettle();

    expect(repository.saves, 1);
    expect(find.text('Применить после подтверждения'), findsOneWidget);
    await tester.tap(find.text('Применить после подтверждения'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Аккаунты, зачисления'), findsOneWidget);
    await tester.tap(find.text('Применить эти решения'));
    await tester.pumpAndSettle();

    expect(repository.applies, 1);
    expect(find.text('Решения применены'), findsOneWidget);
    expect(find.textContaining('Создана новая группа'), findsOneWidget);
  });

  testWidgets('editing names invalidates review and blocks stale apply', (
    tester,
  ) async {
    final repository = _Repository(
      const GroupRecognitionItem(
        rowId: 'row-1',
        sourceRowKey: '1',
        rawGroupName: '1-СбПГС-2',
        classification: 'exact_group',
        candidateGroupIds: ['group-1'],
        candidatePlanIds: ['plan-1'],
        candidateGroups: [
          GroupRecognitionGroupCandidate(
            id: 'group-1',
            name: '1-СбПГС-2',
            label: '1-СбПГС-2 · ПГС · очная · приём 2025',
          ),
        ],
      ),
    );
    await _pump(tester, repository);
    await tester.enterText(find.byType(TextField).first, '2-СбПГС-2');
    await tester.pump();

    expect(find.text('Сохранить решения'), findsNothing);
    expect(find.text('Применить после подтверждения'), findsNothing);
  });

  testWidgets('switching semantic candidate replaces incompatible plan', (
    tester,
  ) async {
    final repository = _Repository(
      const GroupRecognitionItem(
        rowId: 'row-1',
        sourceRowKey: '1',
        rawGroupName: '1-СбПГС-2',
        classification: 'semantic_duplicate',
        candidateGroupIds: ['group-long', 'group-short'],
        candidatePlanIds: ['plan-8', 'plan-12'],
        candidateGroups: [
          GroupRecognitionGroupCandidate(
            id: 'group-long',
            name: 'Длинная программа',
            label: 'Длинная программа · 9 семестров уже есть',
            maxTermSemester: 9,
          ),
          GroupRecognitionGroupCandidate(
            id: 'group-short',
            name: 'Обычная программа',
            label: 'Обычная программа · 8 семестров',
            profile: {'nominal_semesters': 8},
          ),
        ],
        candidatePlans: [
          GroupRecognitionPlanCandidate(
            id: 'plan-8',
            label: 'План на 8 семестров',
            status: 'active',
            nominalSemesters: 8,
          ),
          GroupRecognitionPlanCandidate(
            id: 'plan-12',
            label: 'План на 12 семестров',
            status: 'reviewed',
            nominalSemesters: 12,
          ),
        ],
      ),
    );
    await _pump(tester, repository);

    await tester.tap(
      find.byType(DropdownButtonFormField<GroupRecognitionDecisionAction>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Использовать существующую группу').last);
    await tester.pumpAndSettle();

    final groupDropdown = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.decoration.labelText == 'Существующая группа',
    );
    await tester.tap(groupDropdown);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Длинная программа · 9 семестров уже есть').last,
    );
    await tester.pumpAndSettle();
    expect(find.text('План на 12 семестров'), findsOneWidget);

    await tester.tap(groupDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Обычная программа · 8 семестров').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('План на 8 семестров'), findsOneWidget);
  });
}
