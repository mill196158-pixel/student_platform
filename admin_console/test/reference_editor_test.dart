import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/reference/reference_editor_screen.dart';
import 'package:student_platform_admin/features/content/reference/reference_item.dart';
import 'package:student_platform_admin/features/content/reference/reference_repository.dart';
import 'package:student_platform_admin/features/content/shared/content_icon_picker.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_shell.dart';
import 'package:student_ui/student_ui.dart';

Finder get _createButton => find.byTooltip('Создать черновик');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(WidgetTester tester, ReferenceRepository repo) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReferenceEditorScreen(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'uses VisualEditorShell and StudentReferenceArticleCard preview',
    (tester) async {
      await pumpEditor(tester, LocalReferenceRepository());

      expect(find.byType(VisualEditorShell), findsOneWidget);
      expect(find.byType(VisualEditorListPanel), findsOneWidget);
      expect(find.text('Справочник · статьи'), findsOneWidget);
      expect(find.text('Статьи справочника'), findsOneWidget);
      expect(find.text('Как зайти в личный кабинет'), findsWidgets);
      expect(find.byType(StudentReferenceArticleCard), findsWidgets);
      expect(find.text('Управление категориями'), findsOneWidget);
      expect(find.byType(ContentIconPickerField), findsWidgets);
      expect(find.textContaining('Опубликовано'), findsWidgets);
      expect(find.textContaining('Черновики'), findsWidgets);
      expect(find.textContaining('Архив'), findsWidgets);
    },
  );

  testWidgets('create draft uses local repository', (tester) async {
    final repo = LocalReferenceRepository();
    await pumpEditor(tester, repo);

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final items = await repo.listArticles();
    expect(items.any((e) => e.status == ReferenceArticleStatus.draft), isTrue);
  });

  testWidgets('tapping preview card opens article detail sheet', (
    tester,
  ) async {
    await pumpEditor(tester, LocalReferenceRepository());

    await tester.tap(find.byType(StudentReferenceArticleCard).first);
    await tester.pumpAndSettle();

    expect(find.byType(StudentReferenceArticleDetail), findsOneWidget);
  });

  testWidgets('editing title marks editor dirty', (tester) async {
    await pumpEditor(tester, LocalReferenceRepository());

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    await tester.enterText(titleField, 'Обновлённый заголовок');
    await tester.pump();

    expect(find.text('Есть правки'), findsOneWidget);
  });

  test('local previewAudience returns safe counts', () async {
    final repo = LocalReferenceRepository();
    final items = await repo.listArticles();
    final preview = await repo.previewAudience(items.first.id);
    expect(preview.recipientCount, greaterThan(0));
    expect(preview.audienceMode, 'all');
  });

  test('local demo article retains legacy key when promoted', () async {
    final repo = LocalReferenceRepository();
    final demo = (await repo.listArticles()).firstWhere(
      (item) => item.origin == ContentOrigin.demo,
    );
    expect(demo.legacyKey, 'content:reference_article:login_cabinet');

    final promoted = await repo.promoteDemo(demo.id, demo.rowVersion);
    expect(promoted.origin, ContentOrigin.admin);
    expect(promoted.legacyKey, demo.legacyKey);
    expect(promoted.rowVersion, demo.rowVersion + 1);
  });

  test('local safe delete requires an archived reference article', () async {
    final repo = LocalReferenceRepository();
    final demo = (await repo.listArticles()).first;
    await expectLater(
      repo.safeDelete(demo.id, demo.rowVersion),
      throwsA(isA<ReferenceRepositoryException>()),
    );
    final archived = await repo.archive(demo.id, demo.rowVersion);
    await repo.safeDelete(archived.id, archived.rowVersion);
    expect(
      (await repo.listArticles()).any((item) => item.id == demo.id),
      isFalse,
    );
  });

  test('tryParse succeeds on admin_list_reference_articles fixture', () {
    final raw = File(
      'test/fixtures/admin_list_reference_articles_sample.json',
    ).readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final parsed = ReferenceArticleItem.tryParse(json);
    expect(parsed, isNotNull);
    expect(parsed!.id, json['id']);
    expect(parsed.categoryId, 'cat-materials-001');
    expect(parsed.payload.iconKey, 'download');
    expect(parsed.hasWorkingDraft, isFalse);
  });

  test('local working draft begin save publish flow', () async {
    final repo = LocalReferenceRepository();
    final published = (await repo.listArticles()).firstWhere(
      (item) => item.status == ReferenceArticleStatus.published,
    );
    final editing = await repo.beginEdit(published.id);
    expect(editing.hasWorkingDraft, isTrue);
    expect(editing.workingDraftRowVersion, 1);

    final saved = await repo.saveWorkingDraft(
      editing.copyWith(title: 'Обновлённый заголовок'),
      expectedDraftRowVersion: editing.workingDraftRowVersion!,
    );
    expect(saved.title, 'Обновлённый заголовок');
    expect(saved.workingDraftRowVersion, 2);

    final applied = await repo.publishWorkingDraft(
      published.id,
      expectedDraftRowVersion: saved.workingDraftRowVersion!,
    );
    expect(applied.title, 'Обновлённый заголовок');
    expect(applied.hasWorkingDraft, isFalse);
    expect(applied.workingDraftRowVersion, isNull);
  });

  test('local working draft discard restores canonical', () async {
    final repo = LocalReferenceRepository();
    final published = (await repo.listArticles()).firstWhere(
      (item) => item.status == ReferenceArticleStatus.published,
    );
    final originalTitle = published.title;
    final editing = await repo.beginEdit(published.id);
    await repo.saveWorkingDraft(
      editing.copyWith(title: 'Временный заголовок'),
      expectedDraftRowVersion: editing.workingDraftRowVersion!,
    );
    final restored = await repo.discardWorkingDraft(published.id);
    expect(restored.title, originalTitle);
    expect(restored.hasWorkingDraft, isFalse);
  });

  test('tryParse rejects Stage 14 audience JSON without category_id', () {
    final parsed = ReferenceArticleItem.tryParse({
      'id': 'art-1',
      'title': 'Article',
      'status': 'draft',
      'origin': 'admin',
      'template_key': 'reference_article_v1',
      'schema_version': 2,
      'row_version': 2,
      'audience_mode': 'all',
      'payload': {
        'icon_key': 'help',
        'short_text': 'Short',
        'blocks': [
          {'type': 'text', 'text': 'Body'},
        ],
      },
    });
    expect(parsed, isNull);
  });

  test('tryParse accepts reference_article_admin_json shape', () {
    final parsed = ReferenceArticleItem.tryParse({
      'id': 'art-1',
      'title': 'Article',
      'status': 'draft',
      'origin': 'admin',
      'template_key': 'reference_article_v1',
      'schema_version': 2,
      'row_version': 2,
      'audience_mode': 'all',
      'category_id': 'cat-1',
      'category_title': 'Доступы',
      'payload': {
        'icon_key': 'help',
        'short_text': 'Short',
        'blocks': [
          {'type': 'text', 'text': 'Body'},
        ],
      },
    });
    expect(parsed?.categoryId, 'cat-1');
  });

  test('local upsertCategory and reorderCategories work', () async {
    final repo = LocalReferenceRepository();
    final before = await repo.listCategories();
    expect(before, isNotEmpty);

    final created = await repo.upsertCategory(
      const ReferenceCategoryItem(
        id: '',
        title: 'Новая категория',
        iconKey: 'map',
        sortOrder: 99,
        rowVersion: 0,
        key: 'new_cat',
        status: ReferenceCategoryStatus.draft,
      ),
    );
    expect(created.id, isNotEmpty);
    expect(created.title, 'Новая категория');
    expect(created.status, ReferenceCategoryStatus.draft);

    final published = await repo.upsertCategory(
      created.copyWith(status: ReferenceCategoryStatus.published),
    );
    expect(published.status, ReferenceCategoryStatus.published);
    expect(published.rowVersion, greaterThan(created.rowVersion));

    final all = await repo.listCategories();
    final reversed = all.reversed.toList();
    await repo.reorderCategories(
      [for (final c in reversed) c.id],
      [for (final c in reversed) c.rowVersion],
    );
    final after = await repo.listCategories();
    expect(after.first.id, reversed.first.id);
  });

  test(
    'local safeDeleteCategory removes category on archive_articles',
    () async {
      final repo = LocalReferenceRepository();
      final categories = await repo.listCategories();
      final target = categories.first;
      await repo.safeDeleteCategory(
        id: target.id,
        expectedRowVersion: target.rowVersion,
        mode: 'archive_articles',
      );
      final after = await repo.listCategories();
      expect(after.any((c) => c.id == target.id), isFalse);
    },
  );
}
