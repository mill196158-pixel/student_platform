import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_item.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_editor_screen.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_repository.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(
    WidgetTester tester,
    ProfileFeedRepository repo,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1400,
            height: 1200,
            child: ProfileFeedEditorScreen(repository: repo),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('lists local profile feed in visual editor shell', (
    tester,
  ) async {
    await pumpEditor(tester, LocalProfileFeedRepository());

    expect(find.text('Визуальный редактор ленты профиля'), findsOneWidget);
    expect(find.text('О нас'), findsWidgets);
    expect(find.text('Расписание занятий'), findsWidgets);
    expect(find.byType(StudentProfileFeedCarousel), findsOneWidget);
    expect(find.textContaining('Новости сюда не копируются'), findsOneWidget);
    expect(find.byType(VisualEditorListPanel), findsOneWidget);
  });

  testWidgets('demo filter shows only demo cards', (tester) async {
    final repo = LocalProfileFeedRepository();
    await repo.createDraft(origin: ContentOrigin.admin);
    await pumpEditor(tester, repo);

    await tester.tap(find.widgetWithText(FilterChip, 'Демо'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('О нас'), findsWidgets);
    expect(find.text('Новая карточка'), findsNothing);
  });

  testWidgets('create draft uses local repository', (tester) async {
    final repo = LocalProfileFeedRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    final items = await repo.list();
    expect(items.any((e) => e.status == ProfileFeedStatus.draft), isTrue);
    expect(find.text('Сохранить черновик'), findsOneWidget);
    expect(find.text('Preview аудитории'), findsOneWidget);
    expect(find.textContaining('Черновики'), findsWidgets);
  });

  testWidgets('duplicate creates draft copy', (tester) async {
    final repo = LocalProfileFeedRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.text('О нас').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Дублировать'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final items = await repo.list(status: 'draft');
    expect(items.any((e) => e.title.contains('копия')), isTrue);
  });

  test('local seeds include legacy keys', () async {
    final repo = LocalProfileFeedRepository();
    final items = await repo.list();
    expect(
      items.map((e) => e.legacyKey).whereType<String>().toList(),
      containsAll([
        'content:profile_feed:about',
        'content:profile_feed:schedule',
        'content:profile_feed:discounts',
      ]),
    );
  });

  test('local previewAudience returns safe counts', () async {
    final repo = LocalProfileFeedRepository();
    final items = await repo.list();
    final preview = await repo.previewAudience(items.first.id);
    expect(preview.recipientCount, greaterThan(0));
    expect(preview.audienceMode, 'all');
  });

  test('local unpublish and restore archived', () async {
    final repo = LocalProfileFeedRepository();
    final item = (await repo.list()).first;
    final published = await repo.publish(item.id, item.rowVersion);
    final draft = await repo.unpublish(published.id, published.rowVersion);
    expect(draft.status, ProfileFeedStatus.draft);

    final archived = await repo.archive(draft.id, draft.rowVersion);
    final restored = await repo.restoreArchived(
      archived.id,
      archived.rowVersion,
    );
    expect(restored.status, ProfileFeedStatus.draft);
  });

  test('working draft patch tracks profile feed image asset id', () {
    final item = ProfileFeedItem(
      id: 'pf-1',
      status: ProfileFeedStatus.published,
      origin: ContentOrigin.admin,
      title: 'Card',
      payload: const ProfileFeedPayload(
        title: 'Card',
        subtitle: 'Sub',
        ctaLabel: 'Go',
        imageAssetId: 'asset-image-42',
      ),
      rowVersion: 3,
      priority: 1,
      sortOrder: 0,
      audienceMode: 'all',
      versionNumber: 2,
      hasWorkingDraft: true,
      workingDraftRowVersion: 1,
    );

    final patch = item.toWorkingDraftPatch();
    expect(patch['draft_asset_ids'], ['asset-image-42']);
    expect((patch['payload'] as Map)['image_asset_id'], 'asset-image-42');
  });
}
