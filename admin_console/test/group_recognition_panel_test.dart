import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_panel.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_repository.dart';

class _ExactGroupRepository implements GroupRecognitionRepository {
  _ExactGroupRepository({
    this.items = const [
      GroupRecognitionItem(
        sourceRowKey: '1',
        rawGroupName: '1-СбПГС-2',
        classification: 'exact_group',
        parallelNumber: 1,
        programAliasKey: 'сбпгс',
        courseNumber: 2,
        derivedAdmissionYear: 2025,
        candidateGroupIds: ['group-candidate'],
      ),
    ],
  });

  final List<GroupRecognitionItem> items;
  int previews = 0;

  @override
  Future<List<GroupRecognitionAcademicYear>> listAcademicYears() async {
    return const [
      GroupRecognitionAcademicYear(
        id: 'year-2026',
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
    previews++;
    return GroupRecognitionPreview(
      previewId: 'preview-$previews',
      summary: {
        'total': items.length,
        'exact': 1,
        'new_candidate': 0,
        'blocked': 0,
      },
      applyEnabled: false,
      applyBlocker: 'preview_only',
      items: items,
    );
  }
}

void main() {
  testWidgets('shows parsed course and admission year in safe preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 760,
            child: GroupRecognitionPanel(
              repository: LocalGroupRecognitionRepository(startYear: 2026),
              initialRows: [
                {'name': '1-сб(ПГС)-2'},
                {'name': 'bad group'},
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Проверка названий групп'), findsOneWidget);
    expect(find.textContaining('Сохранение пока отключено'), findsOneWidget);

    await tester.tap(find.text('Быстрая проверка'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Параллель: 1 · код: сбпгс · курс: 2'),
      findsOneWidget,
    );
    expect(find.textContaining('поступление: 2025'), findsOneWidget);
    expect(
      find.textContaining('Код программы ещё не подтверждён'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(find.textContaining('Формат названия не распознан'), findsOneWidget);
    expect(find.text('Только preview'), findsOneWidget);
  });

  testWidgets('duplicate intent is local, constrained and reset after edits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ExactGroupRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 760,
            child: GroupRecognitionPanel(
              repository: repository,
              initialRows: const [
                {'name': '1-СбПГС-2'},
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Быстрая проверка'));
    await tester.pumpAndSettle();

    expect(find.text('Предлагаемое решение по дублю'), findsOneWidget);
    expect(
      find.textContaining('Локальная пометка для проверки'),
      findsOneWidget,
    );
    expect(find.text('Создать отдельную — недоступно'), findsOneWidget);

    ChoiceChip reuseChip() => tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Использовать найденную группу'),
    );
    ChoiceChip aliasChip() => tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Добавить это название как вариант'),
    );

    expect(reuseChip().selected, isFalse);
    expect(reuseChip().onSelected, isNotNull);
    expect(aliasChip().selected, isFalse);
    expect(aliasChip().onSelected, isNull);

    reuseChip().onSelected!(true);
    await tester.pump();
    expect(reuseChip().selected, isTrue);

    await tester.enterText(
      find.byType(TextField).first,
      '1-СбПГС-2\n2-СбПГС-2',
    );
    await tester.pump();
    expect(find.text('Предлагаемое решение по дублю'), findsNothing);

    await tester.tap(find.text('Быстрая проверка'));
    await tester.pumpAndSettle();
    expect(reuseChip().selected, isFalse);
  });

  testWidgets('semantic duplicate enables alias intent for one candidate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ExactGroupRepository(
      items: const [
        GroupRecognitionItem(
          sourceRowKey: '1',
          rawGroupName: '1-Сб(ПГС)-2',
          classification: 'semantic_duplicate',
          candidateGroupIds: ['one-candidate'],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupRecognitionPanel(
            repository: repository,
            initialRows: const [
              {'name': '1-Сб(ПГС)-2'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Быстрая проверка'));
    await tester.pumpAndSettle();

    final reuse = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Использовать найденную группу'),
    );
    final alias = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Добавить это название как вариант'),
    );
    expect(reuse.selected, isFalse);
    expect(alias.selected, isFalse);
    expect(reuse.onSelected, isNotNull);
    expect(alias.onSelected, isNotNull);
  });
}
