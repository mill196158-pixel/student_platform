import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_editor_screen.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_item.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(
    WidgetTester tester,
    VacancyRepository repo,
  ) async {
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

  testWidgets('lists local vacancies and shows shared preview', (
    tester,
  ) async {
    await pumpEditor(tester, LocalVacancyRepository());

    expect(find.text('Вакансии'), findsOneWidget);
    expect(find.text('Junior Flutter Developer'), findsWidgets);
    expect(find.byType(StudentVacancyCard), findsOneWidget);
    expect(
      find.textContaining('User submission не публикуется'),
      findsOneWidget,
    );
  });

  testWidgets('create draft uses local repository', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.text('Новая вакансия'));
    await tester.pumpAndSettle();

    final items = await repo.list();
    expect(items.any((e) => e.status == VacancyStatus.draft), isTrue);
    expect(find.textContaining('Черновик'), findsWidgets);
  });

  testWidgets('invalid create does not write', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    final before = (await repo.list()).length;

    await tester.tap(find.text('Новая вакансия'));
    await tester.pumpAndSettle();

    expect(await repo.list(), hasLength(before + 1));

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), ' ');
    await tester.enterText(fields.at(2), ' ');
    await tester.tap(find.text('Новая вакансия'));
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

  test('local moderate approve requires in_moderation', () async {
    final repo = LocalVacancyRepository();
    final submitted = (await repo.list())
        .firstWhere((e) => e.status == VacancyStatus.submitted);
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
    final submitted = (await repo.list())
        .firstWhere((e) => e.status == VacancyStatus.submitted);
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
    final submitted = (await repo.list())
        .firstWhere((e) => e.status == VacancyStatus.submitted);
    expect(
      () => repo.moderate(
        id: submitted.id,
        action: 'reject',
        expectedRowVersion: submitted.rowVersion,
      ),
      throwsA(isA<VacancyRepositoryException>()),
    );
  });

  testWidgets('shows rejection reason for rejected vacancy', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.text('Быстрые деньги без опыта'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.textContaining('Причина отклонения'),
      200,
      scrollable: scrollable,
    );

    expect(find.textContaining('Причина отклонения'), findsOneWidget);
    expect(find.textContaining('мошенничество'), findsOneWidget);
  });

  testWidgets('requirements and contacts fields are editable on draft',
      (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.text('Новая вакансия'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Требования'),
      200,
      scrollable: scrollable,
    );

    expect(find.text('Требования'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
  });
}
