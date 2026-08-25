import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_item.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_editor_screen.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_repository.dart';
import 'package:student_platform_admin/features/content/reference/content_media_store.dart';
import 'package:student_platform_admin/features/content/shared/content_card_variant_picker.dart';
import 'package:student_platform_admin/features/content/shared/content_icon_picker.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_ui/student_ui.dart';

/// Minimal valid 1x1 PNG for MemoryImage assertions.
final Uint8List _kTestPngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeContentMediaStore extends ContentMediaStore {
  _FakeContentMediaStore(this.bytesByAssetId);

  final Map<String, Uint8List> bytesByAssetId;
  final List<String> downloadedAssetIds = [];

  @override
  Future<Uint8List?> downloadBytes({required String assetId}) async {
    downloadedAssetIds.add(assetId);
    return bytesByAssetId[assetId];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(
    WidgetTester tester,
    ProfileFeedRepository repo,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
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
    expect(
      find.textContaining('Новости сюда не копируются').evaluate().isNotEmpty ||
          find
              .textContaining('Сохранить черновик можно')
              .evaluate()
              .isNotEmpty,
      isTrue,
    );
    expect(find.text('Мой дневник'), findsOneWidget);
    expect(find.byType(StudentProfileScreenPreview), findsOneWidget);
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
    await tester.pump(const Duration(milliseconds: 300));

    final items = await repo.list();
    expect(items.any((e) => e.status == ProfileFeedStatus.draft), isTrue);
    expect(find.text('Сохранить черновик'), findsOneWidget);
    expect(find.text('Свойства карточки'), findsOneWidget);
    expect(find.byType(ContentIconPickerField), findsOneWidget);
    expect(find.textContaining('Черновики'), findsWidgets);
  });

  testWidgets('tapping carousel card opens in-phone detail with back', (
    tester,
  ) async {
    await pumpEditor(tester, LocalProfileFeedRepository());

    final carousel = find.byType(StudentProfileFeedCarousel);
    await tester.tap(
      find
          .descendant(
            of: carousel,
            matching: find.byType(StudentProfileFeedCard),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.byType(StudentProfileFeedCard), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(StudentProfileFeedCarousel), findsOneWidget);
  });

  testWidgets('selecting carousel card syncs list selection', (tester) async {
    await pumpEditor(tester, LocalProfileFeedRepository());

    final carousel = find.byType(StudentProfileFeedCarousel);
    await tester.tap(
      find
          .descendant(of: carousel, matching: find.text('Расписание занятий'))
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Расписание занятий'), findsWidgets);
  });

  test('local duplicate adds draft copy', () async {
    final repo = LocalProfileFeedRepository();
    final source = (await repo.list()).first;
    final copy = await repo.duplicate(source.id);
    expect(copy.title, '${source.title} (копия)');
    expect(copy.status, ProfileFeedStatus.draft);
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
    expect(patch['target_schema_version'], 2);
    expect((patch['payload'] as Map)['image_asset_id'], 'asset-image-42');
  });

  test('ProfileFeedPayload dual-read v2 fields', () {
    final parsed = ProfileFeedPayload.tryParse({
      'title': 'T',
      'subtitle': 'S',
      'cta_label': 'C',
      'iconKey': 'school',
      'icon_asset_id': 'icon-asset-1',
      'cardVariant': 'compact_icon',
      'bg_mode': 'gradient',
      'bg_color': '#DCD0FA',
      'gradientColors': ['#DCD0FA', '#C9B8F3'],
      'gradient_angle': 90,
      'overlay_opacity': 0.35,
      'action': {'kind': 'none'},
    });
    expect(parsed, isNotNull);
    expect(parsed!.iconKey, 'school');
    expect(parsed.iconAssetId, 'icon-asset-1');
    expect(parsed.cardVariant, 'compact_icon');
    expect(parsed.bgMode, 'gradient');
    expect(parsed.gradientAngle, 90);
    expect(parsed.overlayOpacity, 0.35);
    expect(parsed.gradientColors, hasLength(2));

    final wire = parsed.toWireJson();
    expect(wire['icon_key'], 'school');
    expect(wire['card_variant'], 'compact_icon');
    expect(wire['gradient_angle'], 90);
    expect(wire['action'], isNotNull);
  });

  test('ProfileFeedPayload v1 parse succeeds without icon_key', () {
    expect(
      ProfileFeedPayload.tryParse({
        'title': 'T',
        'subtitle': 'S',
        'cta_label': 'C',
      }),
      isNotNull,
    );
  });

  test('ManagedProfileFeedCard accepts schema 2', () {
    final card = ManagedProfileFeedCard.tryParse({
      'id': 'pf-2',
      'template_key': 'profile_feed_card_v1',
      'schema_version': 2,
      'origin': 'admin',
      'payload': {
        'title': 'Card',
        'subtitle': 'Sub',
        'cta_label': 'Go',
        'icon_key': 'info',
        'card_variant': 'gradient_text',
        'gradient_colors': ['#DCD0FA', '#C9B8F3'],
      },
    });
    expect(card, isNotNull);
    expect(card!.payload.iconKey, 'info');
  });

  test('working draft patch includes icon asset and card variant', () {
    final item = ProfileFeedItem(
      id: 'pf-3',
      status: ProfileFeedStatus.published,
      origin: ContentOrigin.admin,
      title: 'Card',
      payload: const ProfileFeedPayload(
        title: 'Card',
        subtitle: 'Sub',
        ctaLabel: 'Go',
        iconAssetId: 'icon-asset-7',
        cardVariant: 'compact_icon',
        gradientColors: [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
      ),
      rowVersion: 2,
      priority: 0,
      sortOrder: 0,
      audienceMode: 'all',
    );

    final patch = item.toWorkingDraftPatch();
    expect(patch['target_schema_version'], 2);
    expect(patch['draft_asset_ids'], ['icon-asset-7']);
    expect((patch['payload'] as Map)['card_variant'], 'compact_icon');
  });

  testWidgets('properties panel shows icon and variant pickers', (
    tester,
  ) async {
    final repo = LocalProfileFeedRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Свойства карточки'), findsOneWidget);
    final propertiesScrollable = find
        .ancestor(
          of: find.text('Свойства карточки'),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byType(ContentCardVariantPicker),
      200,
      scrollable: propertiesScrollable,
    );
    expect(find.byType(ContentIconPickerField), findsOneWidget);
    expect(find.byType(ContentCardVariantPicker), findsOneWidget);
  });

  testWidgets('draft title overlays carousel preview', (tester) async {
    final repo = LocalProfileFeedRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    await tester.enterText(titleField, 'Overlay');
    await tester.pump();

    expect(find.text('Overlay'), findsWidgets);
  });

  testWidgets('published asset-id cards resolve bytes into phone preview', (
    tester,
  ) async {
    final repo = LocalProfileFeedRepository();
    final draft = await repo.createDraft(
      payload: const ProfileFeedPayload(
        title: 'С картинкой',
        subtitle: 'Подзаголовок',
        ctaLabel: 'Открыть',
        imageAssetId: 'asset-preview-1',
        cardVariant: 'image_overlay',
        iconKey: 'info',
      ),
    );
    final published = await repo.publish(draft.id, draft.rowVersion);
    expect(published.status, ProfileFeedStatus.published);

    final media = _FakeContentMediaStore({
      'asset-preview-1': _kTestPngBytes,
    });

    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1400,
            height: 1200,
            child: ProfileFeedEditorScreen(
              repository: repo,
              mediaStore: media,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(media.downloadedAssetIds, contains('asset-preview-1'));

    // Select the published card so PageView builds that page.
    await tester.tap(find.text('С картинкой').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final cards = tester
        .widgetList<StudentProfileFeedCard>(find.byType(StudentProfileFeedCard))
        .where((card) => card.payload.title == 'С картинкой')
        .toList();
    expect(cards, isNotEmpty);
    expect(cards.first.imageBytes, isNotNull);
    expect(cards.first.imageBytes, _kTestPngBytes);
    expect(cards.first.imageLoading, isFalse);
  });
}
