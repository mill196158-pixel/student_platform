import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
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
      find.textContaining('модерацию перед публикацией'),
      findsOneWidget,
    );
    expect(find.textContaining('Stage 17'), findsNothing);
    expect(find.textContaining('schema'), findsNothing);
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

  test('local readyPublish publishes admin/demo draft atomically', () async {
    final repo = LocalVacancyRepository();
    final demo = (await repo.list()).firstWhere(
      (item) => item.origin == ContentOrigin.demo,
    );
    expect(demo.isReadyPublishEligible, isTrue);
    final published = await repo.readyPublish(demo.id, demo.rowVersion);
    expect(published.status, VacancyStatus.published);
    expect(published.rowVersion, demo.rowVersion + 3);
  });

  testWidgets('draft Publish disabled without moderation capability', (
    tester,
  ) async {
    final session = AdminSessionController();
    session.phase = AdminSessionPhase.ready;
    session.capabilities = const AdminCapabilities(
      userId: 'pub-only',
      permissions: {'content.publish', 'content.write', 'content.read'},
      assignments: [],
    );
    final repo = LocalVacancyRepository();

    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1400,
            height: 1200,
            child: VacancyEditorScreen(repository: repo, session: session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Shell hides Publish when onPublish is null (draft shortcut needs moderation).
    expect(find.text('Опубликовать'), findsNothing);
    expect(find.text('Опубликовать изменения'), findsNothing);
  });

  test('readyPublish eligibility excludes user_submission and submitters', () {
    const base = VacancyItem(
      id: 'v1',
      status: VacancyStatus.draft,
      origin: ContentOrigin.admin,
      title: 'T',
      companyName: 'C',
      summary: 'S',
      description: 'D',
      rowVersion: 1,
      priority: 0,
      audienceMode: 'all',
    );
    expect(base.isReadyPublishEligible, isTrue);
    expect(
      base.copyWith(origin: ContentOrigin.userSubmission).isReadyPublishEligible,
      isFalse,
    );
    expect(base.copyWith(submittedBy: 'user-1').isReadyPublishEligible, isFalse);
    expect(
      base.copyWith(status: VacancyStatus.approved).isReadyPublishEligible,
      isFalse,
    );
  });

  test('local publish still requires approved (no draft shortcut)', () async {
    final repo = LocalVacancyRepository();
    final demo = (await repo.list()).firstWhere(
      (item) => item.origin == ContentOrigin.demo,
    );
    expect(
      () => repo.publish(demo.id, demo.rowVersion),
      throwsA(isA<VacancyRepositoryException>()),
    );
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

  test('registerAsset persists background role', () async {
    final repo = LocalVacancyRepository();
    final draft = await repo.createDraft(
      draft: const VacancyItem(
        id: 'tmp',
        status: VacancyStatus.draft,
        origin: ContentOrigin.admin,
        title: 'Background media vacancy',
        companyName: 'Org',
        summary: 'Summary',
        description: 'Body',
        rowVersion: 1,
        priority: 0,
        audienceMode: 'all',
      ),
    );

    final backgroundId = await repo.registerAsset(
      vacancyId: draft.id,
      bytes: const [9, 8, 7],
      contentType: 'image/png',
      title: 'background.png',
      role: 'background',
    );

    final item = await repo.get(draft.id);
    expect(item.assetIdForRole('background'), backgroundId);
    expect(repo.assetRole(backgroundId), 'background');
  });

  testWidgets('draft title edit updates phone preview card', (tester) async {
    final repo = LocalVacancyRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Название',
    );
    await tester.enterText(titleField, 'Draft vacancy title');
    await tester.pump();

    expect(find.text('Draft vacancy title'), findsWidgets);
  });

  test(
    'registerAsset persists logo/cover roles; clear deletes asset',
    () async {
      final repo = LocalVacancyRepository();
      final draft = await repo.createDraft(
        draft: const VacancyItem(
          id: 'tmp',
          status: VacancyStatus.draft,
          origin: ContentOrigin.admin,
          title: 'Role media vacancy',
          companyName: 'Org',
          summary: 'Summary',
          description: 'Body',
          rowVersion: 1,
          priority: 0,
          audienceMode: 'all',
        ),
      );

      final logoId = await repo.registerAsset(
        vacancyId: draft.id,
        bytes: const [1, 2, 3],
        contentType: 'image/png',
        title: 'logo.png',
        role: 'logo',
      );
      final coverId = await repo.registerAsset(
        vacancyId: draft.id,
        bytes: const [4, 5, 6],
        contentType: 'image/jpeg',
        title: 'cover.jpg',
        role: 'cover',
      );

      var item = await repo.get(draft.id);
      expect(item.assetIdForRole('logo'), logoId);
      expect(item.assetIdForRole('cover'), coverId);
      expect(repo.assetRole(logoId), 'logo');
      expect(repo.assetRole(coverId), 'cover');

      final logo2 = await repo.registerAsset(
        vacancyId: draft.id,
        bytes: const [7, 8],
        contentType: 'image/png',
        title: 'logo2.png',
        role: 'logo',
      );
      item = await repo.get(draft.id);
      expect(item.assetIdForRole('logo'), logo2);
      expect(repo.assetRole(logoId), 'attachment');

      await repo.deleteAsset(logo2);
      item = await repo.get(draft.id);
      expect(item.assetIdForRole('logo'), isNull);
      expect(item.assetIds.contains(logo2), isFalse);
    },
  );

  test(
    'working draft logo replace keeps canonical until publish; discard restores',
    () async {
      final repo = LocalVacancyRepository();
      var item = await repo.createDraft(
        draft: const VacancyItem(
          id: 'tmp',
          status: VacancyStatus.draft,
          origin: ContentOrigin.admin,
          title: 'Published visual vacancy',
          companyName: 'Org',
          summary: 'Summary',
          description: 'Body',
          rowVersion: 1,
          priority: 0,
          audienceMode: 'all',
        ),
      );
      final canonicalLogo = await repo.registerAsset(
        vacancyId: item.id,
        bytes: const [1],
        contentType: 'image/png',
        title: 'canon.png',
        role: 'logo',
      );
      item = await repo.get(item.id);
      // Local publish requires approved; walk the moderation path.
      item = await repo.moderate(
        id: item.id,
        action: 'take_in_moderation',
        expectedRowVersion: item.rowVersion,
      );
      item = await repo.moderate(
        id: item.id,
        action: 'approve',
        expectedRowVersion: item.rowVersion,
      );
      item = await repo.publish(item.id, item.rowVersion);
      expect(item.status, VacancyStatus.published);
      expect(item.assetIdForRole('logo'), canonicalLogo);

      item = await repo.beginEdit(item.id);
      expect(item.hasWorkingDraft, isTrue);

      final draftLogo = await repo.registerAsset(
        vacancyId: item.id,
        bytes: const [2],
        contentType: 'image/png',
        title: 'draft.png',
        role: 'logo',
      );
      item = await repo.get(item.id);
      expect(item.assetIdForRole('logo'), draftLogo);
      expect(
        item.assets.any((a) => a.id == canonicalLogo && a.role == 'logo'),
        isTrue,
        reason: 'canonical logo role must stay until publish',
      );

      await repo.clearVisualRole(vacancyId: item.id, role: 'logo');
      item = await repo.get(item.id);
      expect(item.isVisualRoleCleared('logo'), isTrue);
      expect(item.assetIdForRole('logo'), isNull);
      expect(
        item.assets.any((a) => a.id == canonicalLogo && a.role == 'logo'),
        isTrue,
        reason: 'clear during WD must not demote/delete canonical',
      );

      item = await repo.discardWorkingDraft(item.id);
      expect(item.hasWorkingDraft, isFalse);
      expect(item.isVisualRoleCleared('logo'), isFalse);
      expect(item.assetIdForRole('logo'), canonicalLogo);

      item = await repo.beginEdit(item.id);
      final draftRv = item.workingDraftRowVersion ?? 1;
      final replacement = await repo.registerAsset(
        vacancyId: item.id,
        bytes: const [3],
        contentType: 'image/png',
        title: 'next.png',
        role: 'logo',
      );
      final published = await repo.publishWorkingDraft(
        item.id,
        expectedDraftRowVersion: draftRv,
      );
      expect(published.assetIdForRole('logo'), replacement);
      expect(published.assets.any((a) => a.id == canonicalLogo), isFalse);
    },
  );
}
