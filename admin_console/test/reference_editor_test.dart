import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/reference/reference_editor_screen.dart';
import 'package:student_platform_admin/features/content/reference/reference_item.dart';
import 'package:student_platform_admin/features/content/reference/reference_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(
    WidgetTester tester,
    ReferenceRepository repo,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1400,
            height: 1200,
            child: ReferenceEditorScreen(repository: repo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists local reference articles and shared preview', (
    tester,
  ) async {
    await pumpEditor(tester, LocalReferenceRepository());

    expect(find.text('Справочник'), findsOneWidget);
    expect(find.text('Как зайти в личный кабинет'), findsWidgets);
    expect(find.byType(StudentReferenceArticleCard), findsOneWidget);
    expect(find.textContaining('reference_article_v1'), findsOneWidget);
  });

  testWidgets('create draft uses local repository', (tester) async {
    final repo = LocalReferenceRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.text('Новая статья'));
    await tester.pumpAndSettle();

    final items = await repo.listArticles();
    expect(items.any((e) => e.status == ReferenceArticleStatus.draft), isTrue);
  });

  test('local previewAudience returns safe counts', () async {
    final repo = LocalReferenceRepository();
    final items = await repo.listArticles();
    final preview = await repo.previewAudience(items.first.id);
    expect(preview.recipientCount, greaterThan(0));
    expect(preview.audienceMode, 'all');
  });

  test('tryParse rejects Stage 14 audience JSON without category_id', () {
    // Guards the Stage 16.3 wrap of admin_set_content_audience:
    // generic content_item_to_admin_json must not be accepted as a reference article.
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
}
