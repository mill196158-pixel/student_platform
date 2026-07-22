import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_platform_admin/features/content/news/supabase_news_repository.dart';
import 'package:student_ui/student_ui.dart';

class _FakeRpc implements NewsRpcClient {
  final Map<String, dynamic> rows = {};
  final List<Map<String, dynamic>> calls = [];

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    calls.add({'fn': function, 'params': params});
    switch (function) {
      case 'admin_get_news':
        final id = params?['p_id']?.toString();
        return rows[id];
      case 'admin_update_news_draft':
        final id = params?['p_id']?.toString();
        final patch = Map<String, dynamic>.from(params?['p_patch'] as Map);
        final current = Map<String, dynamic>.from(rows[id] as Map);
        if (!patch.containsKey('image_path')) {
          // omit — keep previous
        } else {
          final next = patch['image_path']?.toString();
          current['image_path'] = (next == null || next.isEmpty) ? null : next;
        }
        current['title'] = patch['title'] ?? current['title'];
        current['version_number'] =
            ((current['version_number'] as int?) ?? 1) + 1;
        rows[id!] = current;
        return current;
      case 'admin_list_news_versions':
        final id = params?['p_id']?.toString();
        final snap = Map<String, dynamic>.from(rows[id] as Map);
        return [
          {
            'version_number': snap['version_number'],
            'created_at': DateTime.now().toIso8601String(),
            'snapshot': snap,
          },
        ];
      default:
        throw StateError('unexpected $function');
    }
  }
}

NewsItem _item({
  String id = 'n1',
  String? imagePath =
      'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.png',
  String title = 'Hello',
}) {
  return NewsItem(
    id: id,
    title: title,
    subtitle: 'sub',
    body: 'body',
    variant: StudentHomeNewsVariant.imageOverlay,
    colors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
    imagePath: imagePath,
  );
}

void main() {
  test('text save omits image_path so existing path is not wiped', () {
    final patch = _item().toPatchJson();
    expect(patch.containsKey('image_path'), isFalse);
  });

  test('explicit clear sends empty image_path', () {
    final patch = _item().toPatchJson(imagePathPatch: NewsImagePathPatch.clear);
    expect(patch['image_path'], '');
  });

  test('set patch sends new path only after upload intent', () {
    final patch = _item(
      imagePath:
          'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/cccccccc-cccc-cccc-cccc-cccccccccccc.png',
    ).toPatchJson(imagePathPatch: NewsImagePathPatch.set);
    expect(patch['image_path'], contains('cccccccc'));
  });

  test('local repo omit keeps previous path on text edit', () async {
    final repo = LocalNewsRepository(seed: [_item(title: 'Old')]);
    final edited = _item(title: 'New', imagePath: null);
    final saved = await repo.updateDraft(
      edited,
      imagePathPatch: NewsImagePathPatch.omit,
    );
    expect(saved.title, 'New');
    expect(saved.imagePath, isNotNull);
    expect(saved.imagePath, contains('bbbbbbbb'));
  });

  test('local repo clear removes image_path', () async {
    final repo = LocalNewsRepository(seed: [_item()]);
    final saved = await repo.updateDraft(
      _item(),
      imagePathPatch: NewsImagePathPatch.clear,
    );
    expect(saved.imagePath, isNull);
  });

  test('local repo versions keep image_path after update', () async {
    final repo = LocalNewsRepository(seed: [_item()]);
    await repo.updateDraft(
      _item(title: 'v2'),
      imagePathPatch: NewsImagePathPatch.omit,
    );
    final versions = await repo.listVersions('n1');
    expect(versions, isNotEmpty);
    final latest = await repo.getNews('n1');
    expect(latest.imagePath, isNotNull);
  });

  test('supabase updateDraft omit does not send image_path key', () async {
    final rpc = _FakeRpc();
    final row = _item().toPatchJson(imagePathPatch: NewsImagePathPatch.set);
    row['id'] = 'n1';
    row['status'] = 'draft';
    row['version_number'] = 1;
    row['image_path'] =
        'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.png';
    rpc.rows['n1'] = row;

    final repo = SupabaseNewsRepository(rpcClient: rpc);
    await repo.updateDraft(
      _item(title: 'Edited'),
      imagePathPatch: NewsImagePathPatch.omit,
    );
    final call = rpc.calls.singleWhere(
      (c) => c['fn'] == 'admin_update_news_draft',
    );
    final patch = Map<String, dynamic>.from(
      (call['params'] as Map)['p_patch'] as Map,
    );
    expect(patch.containsKey('image_path'), isFalse);
    expect(rpc.rows['n1']!['image_path'], isNotNull);
  });

  test('supabase updateDraft set persists new path', () async {
    final rpc = _FakeRpc();
    rpc.rows['n1'] = {
      'id': 'n1',
      'title': 'Old',
      'subtitle': 's',
      'body': 'b',
      'variant': 'imageOverlay',
      'status': 'draft',
      'gradient_colors': ['#7367F0', '#B784F7'],
      'image_path':
          'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.png',
      'image_focus_x': 0,
      'image_focus_y': 0,
      'overlay_opacity': 0.4,
      'is_hidden': false,
      'priority': 0,
      'sort_order': 0,
      'version_number': 1,
      'audience_type': 'all',
    };
    final repo = SupabaseNewsRepository(rpcClient: rpc);
    const next =
        'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/dddddddd-dddd-dddd-dddd-dddddddddddd.png';
    final saved = await repo.updateDraft(
      _item(imagePath: next, title: 'New'),
      imagePathPatch: NewsImagePathPatch.set,
    );
    expect(saved.imagePath, next);
  });

  testWidgets('image variants do not paint folder/icon overlay in story', (
    tester,
  ) async {
    final png = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x02,
      0x00,
      0x00,
      0x00,
      0x90,
      0x77,
      0x53,
      0xDE,
      0x00,
      0x00,
      0x00,
      0x0C,
      0x49,
      0x44,
      0x41,
      0x54,
      0x08,
      0xD7,
      0x63,
      0xF8,
      0xCF,
      0xC0,
      0x00,
      0x00,
      0x00,
      0x03,
      0x00,
      0x01,
      0x00,
      0x05,
      0xFE,
      0xD4,
      0xEF,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

    for (final variant in [
      StudentHomeNewsVariant.imageOnly,
      StudentHomeNewsVariant.imageOverlay,
      StudentHomeNewsVariant.imageWithText,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentNewsStorySheet(
              news: [
                StudentHomeNews(
                  id: 'x',
                  title: 'T',
                  subtitle: 'S',
                  body: 'B',
                  icon: Icons.folder_copy_outlined,
                  gradientColors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
                  variant: variant,
                  imageBytes: png,
                  publishedAt: DateTime(2026, 7, 22),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);
      expect(find.byType(Image), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('gradientText keeps thematic icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentNewsStorySheet(
            news: [
              StudentHomeNews(
                id: 'g',
                title: 'Grad',
                subtitle: 'S',
                body: 'B',
                icon: Icons.campaign_outlined,
                gradientColors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.campaign_outlined), findsWidgets);
  });
}
