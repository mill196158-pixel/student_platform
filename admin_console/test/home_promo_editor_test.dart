import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_editor_screen.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_item.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_repository.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_platform_admin/features/content/shared/content_action_model.dart';
import 'package:student_platform_admin/features/content/shared/content_preview_binder.dart';
import 'package:student_platform_admin/features/content/shared/content_preview_mode.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_shell.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';

Finder get _createButton => find.byTooltip('Создать черновик');

void main() {
  testWidgets(
    'Home promo editor uses VisualEditorShell and StudentHomePromoCard',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VisualEditorShell), findsOneWidget);
      expect(find.byType(VisualEditorListPanel), findsOneWidget);
      expect(find.byType(StudentHomeView), findsOneWidget);
      expect(find.byType(StudentHomePromoCard), findsOneWidget);
      expect(find.text('Застрял с заданием?'), findsWidgets);
      expect(find.text('Promo-карточки'), findsOneWidget);
      expect(find.textContaining('Опубликовано'), findsWidgets);
      expect(find.textContaining('Черновики'), findsWidgets);
      expect(find.textContaining('Архив'), findsWidgets);
    },
  );

  testWidgets('demo badge appears for seeded demo item', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Демо'), findsWidgets);
    expect(find.text('Пример'), findsOneWidget);
  });

  testWidgets('editing title updates shared preview renderer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    expect(titleField, findsOneWidget);
    await tester.enterText(titleField, 'Новый заголовок');
    await tester.pump();

    expect(find.text('Новый заголовок'), findsWidgets);
    expect(find.text('Есть правки'), findsOneWidget);
  });

  testWidgets('dirty warning appears after unsaved edits', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Есть правки'), findsNothing);

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    await tester.enterText(titleField, 'Изменено');
    await tester.pump();

    expect(find.text('Есть правки'), findsOneWidget);
    expect(
      find.textContaining('несохранённые изменения', findRichText: true),
      findsWidgets,
    );
  });

  test('local working draft begin save publish flow', () async {
    final repo = LocalHomePromoRepository();
    final published = (await repo.list()).first;
    expect(published.isPublished, isTrue);

    final editing = await repo.beginEdit(published.id);
    expect(editing.hasWorkingDraft, isTrue);

    final saved = await repo.saveWorkingDraft(
      editing.copyWith(title: 'Новый promo заголовок'),
      expectedDraftRowVersion: editing.workingDraftRowVersion!,
    );
    expect(saved.title, 'Новый promo заголовок');

    final applied = await repo.publishWorkingDraft(
      published.id,
      expectedDraftRowVersion: saved.workingDraftRowVersion!,
    );
    expect(applied.title, 'Новый promo заголовок');
    expect(applied.hasWorkingDraft, isFalse);
  });

  test('local working draft discard clears overlay', () async {
    final repo = LocalHomePromoRepository();
    final published = (await repo.list()).first;
    final editing = await repo.beginEdit(published.id);
    await repo.saveWorkingDraft(
      editing.copyWith(title: 'Черновик promo'),
      expectedDraftRowVersion: editing.workingDraftRowVersion!,
    );
    final restored = await repo.discardWorkingDraft(published.id);
    expect(restored.title, published.title);
    expect(restored.hasWorkingDraft, isFalse);
  });

  test('working draft patch persists home_slot and schema v2 target', () {
    final item = HomePromoItem(
      id: 'hp-1',
      status: HomePromoStatus.draft,
      origin: ContentOrigin.admin,
      title: 'Promo',
      payload: HomePromoPayload.tryParse({
        'title': 'Promo',
        'subtitle': 'Sub',
        'icon_key': 'psychology',
        'gradient_colors': ['#FFFBFF', '#F3EEF9'],
        'cta_label': 'Go',
        'dismissible': true,
        'home_slot': 'after_news',
        'card_variant': 'gradient_text',
        'action': contentActionToWire(
          const ContentActionSelection(
            kind: ContentActionKind.appScreen,
            screenKey: 'info',
          ),
        ),
      })!,
      rowVersion: 1,
      priority: 0,
      sortOrder: 0,
      audienceMode: 'all',
    );

    final patch = item.toWorkingDraftPatch();
    expect(patch['target_schema_version'], 2);
    final payload = patch['payload'] as Map<String, dynamic>;
    expect(payload['home_slot'], 'after_news');
    expect(payload['action'], isNotNull);
  });

  testWidgets('changing home slot marks draft dirty', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    await tester.enterText(titleField, 'Slot test');
    await tester.pump();

    expect(find.text('Есть правки'), findsOneWidget);
  });

  testWidgets('preview mode toggle switches between draft labels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('С текущими правками'), findsOneWidget);
    expect(find.text('Как опубликовано'), findsOneWidget);

    await tester.tap(find.text('Как опубликовано'));
    await tester.pumpAndSettle();

    expect(find.text('Застрял с заданием?'), findsWidgets);
  });

  test('preview binder overlays when editing working draft', () {
    expect(
      shouldOverlayLiveDraft(
        isDraft: false,
        editingWorkingDraft: true,
        dirty: false,
        mode: ContentPreviewMode.effectiveDraft,
      ),
      isTrue,
    );
  });

  testWidgets('home preview uses StudentHomeView with promo placements', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final homeView = tester.widget<StudentHomeView>(find.byType(StudentHomeView));
    expect(homeView.homePromoPlacements, isNotEmpty);
    expect(homeView.hideHomePromo, isFalse);
  });

  testWidgets('custom icon upload controls are visible on draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    expect(find.text('Загрузить свою'), findsOneWidget);
    expect(find.textContaining('приоритет над встроенной'), findsOneWidget);
  });

  testWidgets('home preview loads published news when news repo injected', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            newsRepository: LocalNewsRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final homeView = tester.widget<StudentHomeView>(find.byType(StudentHomeView));
    expect(
      homeView.data.news.any(
        (item) => item.title.contains('Добро пожаловать в новый семестр'),
      ),
      isTrue,
    );
  });
}
