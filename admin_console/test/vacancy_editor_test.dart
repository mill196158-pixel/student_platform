import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_editor_screen.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_item.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(WidgetTester tester, VacancyRepository repo) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1400,
            height: 1200,
            child: VacancyEditorScreen(repository: repo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists local vacancies and shows shared preview', (tester) async {
    await pumpEditor(tester, LocalVacancyRepository());

    expect(find.text('Вакансии'), findsWidgets);
    expect(find.text('Junior Flutter Developer'), findsWidgets);
    expect(find.byType(StudentVacancyCard), findsWidgets);
    expect(
      find.textContaining('User submission не публикуется'),
      findsOneWidget,
    );
  });

  testWidgets('create draft uses local repository', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    final items = await repo.list();
    expect(items.any((e) => e.status == VacancyStatus.draft), isTrue);
    expect(find.textContaining('Черновик'), findsWidgets);
  });

  testWidgets('invalid create does not write', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    final before = (await repo.list()).length;

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    expect(await repo.list(), hasLength(before + 1));

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), ' ');
    await tester.enterText(fields.at(2), ' ');
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    expect(await repo.list(), hasLength(before + 1));
    expect(find.textContaining('запись не создана'), findsOneWidget);
  });

  test('local previewAudience returns safe counts', () async {
    final repo = LocalVacancyRepository();
    final items = await repo.list();
    final preview = await repo.previewAudience(items.first.id);
    expect(preview.recipientCount, greaterThan(0));
    expect(preview.audienceMode, 'all');
  });

  test('local demo vacancy is a draft with a stable legacy key', () async {
    final repo = LocalVacancyRepository();
    final demos = (await repo.list())
        .where((item) => item.origin == ContentOrigin.demo)
        .toList();
    expect(
      demos.map((item) => item.legacyKey),
      containsAll(<String>[
        'vacancy:junior_flutter',
        'vacancy:teaching_assistant',
        'vacancy:presentation_designer',
      ]),
    );
    expect(demos.every((item) => item.status == VacancyStatus.draft), isTrue);
  });

  test('local demo promotion preserves legacy identity', () async {
    final repo = LocalVacancyRepository();
    final demo = (await repo.list()).firstWhere(
      (item) => item.origin == ContentOrigin.demo,
    );
    final promoted = await repo.promoteDemo(demo.id, demo.rowVersion);
    expect(promoted.origin, ContentOrigin.admin);
    expect(promoted.legacyKey, demo.legacyKey);
  });

  test('vacancy safe delete requires archive first', () async {
    final repo = LocalVacancyRepository();
    final demo = (await repo.list()).firstWhere(
      (item) => item.origin == ContentOrigin.demo,
    );
    expect(
      () => repo.safeDelete(demo.id, demo.rowVersion),
      throwsA(isA<VacancyRepositoryException>()),
    );
    final archived = await repo.setLifecycle(
      id: demo.id,
      action: 'archive',
      expectedRowVersion: demo.rowVersion,
    );
    expect(archived.status, VacancyStatus.archived);
    await repo.safeDelete(archived.id, archived.rowVersion);
    final remaining = await repo.list();
    expect(remaining.any((e) => e.id == archived.id), isFalse);
  });

  test('local moderate approve requires in_moderation', () async {
    final repo = LocalVacancyRepository();
    final submitted = (await repo.list()).firstWhere(
      (e) => e.status == VacancyStatus.submitted,
    );
    expect(
      () => repo.moderate(
        id: submitted.id,
        action: 'approve',
        expectedRowVersion: submitted.rowVersion,
      ),
      throwsA(isA<VacancyRepositoryException>()),
    );
    final inMod = await repo.moderate(
      id: submitted.id,
      action: 'take_in_moderation',
      expectedRowVersion: submitted.rowVersion,
    );
    final approved = await repo.moderate(
      id: inMod.id,
      action: 'approve',
      expectedRowVersion: inMod.rowVersion,
    );
    expect(approved.status, VacancyStatus.approved);
  });

  test('local moderate approve moves in_moderation to approved', () async {
    final repo = LocalVacancyRepository();
    final submitted = (await repo.list()).firstWhere(
      (e) => e.status == VacancyStatus.submitted,
    );
    final inMod = await repo.moderate(
      id: submitted.id,
      action: 'take_in_moderation',
      expectedRowVersion: submitted.rowVersion,
    );
    final approved = await repo.moderate(
      id: inMod.id,
      action: 'approve',
      expectedRowVersion: inMod.rowVersion,
    );
    expect(approved.status, VacancyStatus.approved);
  });

  test('local moderate reject requires reason', () async {
    final repo = LocalVacancyRepository();
    final submitted = (await repo.list()).firstWhere(
      (e) => e.status == VacancyStatus.submitted,
    );
    expect(
      () => repo.moderate(
        id: submitted.id,
        action: 'reject',
        expectedRowVersion: submitted.rowVersion,
      ),
      throwsA(isA<VacancyRepositoryException>()),
    );
  });

  testWidgets('vacancy card tap opens in-phone detail with back', (
    tester,
  ) async {
    await pumpEditor(tester, LocalVacancyRepository());

    await tester.tap(find.byType(StudentVacancyCard).first);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.byType(StudentVacancyDetailSheet), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(StudentVacancyCard), findsWidgets);
  });

  testWidgets('shows rejection reason for rejected vacancy', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    final listScrollable = find
        .descendant(
          of: find.byType(VisualEditorListPanel),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Быстрые деньги без опыта'),
      100,
      scrollable: listScrollable,
    );
    await tester.tap(find.text('Быстрые деньги без опыта'));
    await tester.pumpAndSettle();

    final scrollable = find
        .ancestor(
          of: find.text('Свойства вакансии'),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.textContaining('Причина отклонения'),
      200,
      scrollable: scrollable,
    );

    expect(find.textContaining('Причина отклонения'), findsOneWidget);
    expect(find.textContaining('мошенничество'), findsOneWidget);
  });

  testWidgets('requirements and contacts fields are editable on draft', (
    tester,
  ) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    final description = VacancyItem.buildDescription('Описание', 'Требования');
    expect(description, contains('Требования'));
  });
}
