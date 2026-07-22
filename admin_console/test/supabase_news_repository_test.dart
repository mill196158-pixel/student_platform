import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/supabase_news_repository.dart';
import 'package:student_ui/student_ui.dart';

class _FakeRpcClient implements NewsRpcClient {
  _FakeRpcClient(this.responder);

  final dynamic Function(String function, Map<String, dynamic>? params)
  responder;

  final List<({String function, Map<String, dynamic>? params})> calls = [];

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    calls.add((function: function, params: params));
    return responder(function, params);
  }
}

Map<String, dynamic> _row({
  required String id,
  String status = 'draft',
  String variant = 'gradientText',
  String title = 'Заголовок',
  int version = 1,
  List<String> colors = const ['#7367F0', '#B784F7'],
}) {
  return {
    'id': id,
    'status': status,
    'sort_order': 0,
    'priority': 0,
    'variant': variant,
    'title': title,
    'subtitle': 'Подзаголовок',
    'body': 'Текст',
    'gradient_colors': colors,
    'image_path': null,
    'image_focus_x': 0.0,
    'image_focus_y': 0.0,
    'overlay_opacity': 0.42,
    'is_hidden': false,
    'version_number': version,
    'published_at': status == 'published' ? '2026-07-22T08:00:00Z' : null,
    'created_at': '2026-07-22T07:00:00Z',
    'updated_at': '2026-07-22T07:30:00Z',
  };
}

void main() {
  test('listNews parses admin_list_news array', () async {
    final fake = _FakeRpcClient((fn, params) {
      expect(fn, 'admin_list_news');
      return [
        _row(id: 'a', title: 'Первая'),
        _row(id: 'b', status: 'published', title: 'Вторая'),
      ];
    });
    final repo = SupabaseNewsRepository(rpcClient: fake);

    final items = await repo.listNews();

    expect(items, hasLength(2));
    expect(items.first.id, 'a');
    expect(items.first.colors, hasLength(2));
    expect(items[1].status, NewsStatus.published);
    expect(items[1].publishedAt, isNotNull);
  });

  test('createDraft sends variant label and parses the row', () async {
    final fake = _FakeRpcClient((fn, params) {
      expect(fn, 'admin_create_news_draft');
      expect(params?['p_variant'], 'imageOverlay');
      return _row(id: 'new-1', variant: 'imageOverlay');
    });
    final repo = SupabaseNewsRepository(rpcClient: fake);

    final item = await repo.createDraft(
      variant: StudentHomeNewsVariant.imageOverlay,
    );

    expect(item.id, 'new-1');
    expect(item.variant, StudentHomeNewsVariant.imageOverlay);
  });

  test('updateDraft posts a patch payload', () async {
    late Map<String, dynamic> sentPatch;
    final fake = _FakeRpcClient((fn, params) {
      expect(fn, 'admin_update_news_draft');
      sentPatch = params?['p_patch'] as Map<String, dynamic>;
      return _row(id: 'x', title: 'Обновлено', version: 2);
    });
    final repo = SupabaseNewsRepository(rpcClient: fake);

    const source = NewsItem(
      id: 'x',
      title: 'Обновлено',
      subtitle: 'Sub',
      body: 'Body',
      variant: StudentHomeNewsVariant.gradientText,
      colors: [Color(0xFF7367F0), Color(0xFFB784F7)],
    );
    final updated = await repo.updateDraft(source);

    expect(updated.versionNumber, 2);
    expect(sentPatch['title'], 'Обновлено');
    expect(sentPatch['gradient_colors'], contains('#7367F0'));
    expect(sentPatch['variant'], 'gradientText');
    expect(sentPatch.containsKey('image_path'), isFalse);
  });

  test('publish calls admin_publish_news with the id', () async {
    final fake = _FakeRpcClient((fn, params) {
      expect(fn, 'admin_publish_news');
      expect(params?['p_id'], 'pub-1');
      return _row(id: 'pub-1', status: 'published', version: 3);
    });
    final repo = SupabaseNewsRepository(rpcClient: fake);

    final item = await repo.publish('pub-1');

    expect(item.status, NewsStatus.published);
    expect(item.publishedAt, isNotNull);
  });

  test('restoreVersion sends version number and returns row', () async {
    final fake = _FakeRpcClient((fn, params) {
      expect(fn, 'admin_restore_news_version');
      expect(params?['p_id'], 'r-1');
      expect(params?['p_version_number'], 2);
      return _row(id: 'r-1', title: 'Восстановлено', version: 5);
    });
    final repo = SupabaseNewsRepository(rpcClient: fake);

    final item = await repo.restoreVersion('r-1', 2);

    expect(item.title, 'Восстановлено');
    expect(item.versionNumber, 5);
  });

  test('listVersions parses admin_list_news_versions', () async {
    final fake = _FakeRpcClient((fn, params) {
      expect(fn, 'admin_list_news_versions');
      return [
        {
          'version_number': 2,
          'created_at': '2026-07-22T07:30:00Z',
          'created_by': 'u-1',
          'snapshot': {'title': 'v2', 'status': 'published'},
        },
        {
          'version_number': 1,
          'created_at': '2026-07-22T07:00:00Z',
          'created_by': 'u-1',
          'snapshot': {'title': 'v1', 'status': 'draft'},
        },
      ];
    });
    final repo = SupabaseNewsRepository(rpcClient: fake);

    final versions = await repo.listVersions('r-1');

    expect(versions, hasLength(2));
    expect(versions.first.versionNumber, 2);
    expect(versions.first.title, 'v2');
    expect(versions.first.status, NewsStatus.published);
  });
}
