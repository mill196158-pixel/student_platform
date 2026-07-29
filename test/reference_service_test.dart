import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/reference_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRpc implements ReferenceRpcClient {
  _FakeRpc({this.response, this.error});

  dynamic response;
  Object? error;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    if (error != null) throw error!;
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> sampleBundle({List<Map<String, dynamic>>? articles}) {
    return {
      'categories': [
        {
          'id': 'cat-1',
          'title': 'Доступы',
          'icon_key': 'login',
          'sort_order': 0,
          'status': 'published',
        },
      ],
      'articles': articles ??
          [
            {
              'id': '11111111-1111-1111-1111-111111111111',
              'title': 'Managed article',
              'template_key': 'reference_article_v1',
              'schema_version': 2,
              'origin': 'admin',
              'sort_order': 0,
              'category_id': 'cat-1',
              'category_title': 'Доступы',
              'payload': {
                'icon_key': 'login',
                'short_text': 'Summary',
                'blocks': [
                  {'type': 'text', 'text': 'Details'},
                ],
              },
            },
          ],
    };
  }

  test('loads managed bundle and writes cache', () async {
    final rpc = _FakeRpc(response: sampleBundle());
    final service = ReferenceService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.isDemoFallback, isFalse);
    expect(result.displayArticles.first.title, 'Managed article');

    final cached = await service.loadCached();
    expect(cached.bundle?.articles.first.id, result.bundle?.articles.first.id);
  });

  test('successful empty hides reference and does not resurrect demo', () async {
    final rpc = _FakeRpc(response: {'categories': [], 'articles': []});
    final service = ReferenceService(rpcClient: rpc);
    final result = await service.load();
    expect(result.intentionallyEmpty, isTrue);
    expect(result.hideReference, isTrue);
    expect(result.displayArticles, isEmpty);
  });

  test('missing RPC 42883 dual-reads to labeled demo', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'function get_my_reference_bundle() does not exist',
        code: '42883',
      ),
    );
    final service = ReferenceService(rpcClient: rpc);
    final result = await service.load();
    expect(result.rpcUnavailable, isTrue);
    expect(result.isDemoFallback, isTrue);
    expect(result.displayArticles, isNotEmpty);
    expect(result.displayArticles.first.showDemoBadge, isTrue);
  });

  test('access denial clears cache', () async {
    SharedPreferences.setMockInitialValues({
      'reference_bundle_v1__user-a': jsonEncode(sampleBundle()),
    });
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'forbidden',
        code: '42501',
      ),
    );
    final service = ReferenceService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.accessDenied, isTrue);
    expect(result.displayArticles, isEmpty);

    final cached = await service.loadCached();
    expect(cached.isDemoFallback, isTrue);
  });

  test('permission errors are not treated as missing RPC', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'permission denied for function get_my_reference_bundle',
        code: '42501',
      ),
    );
    final service = ReferenceService(rpcClient: rpc);
    final result = await service.load();
    expect(result.accessDenied, isTrue);
    expect(result.rpcUnavailable, isFalse);
  });

  test('clearAll removes user-scoped keys', () async {
    SharedPreferences.setMockInitialValues({
      'reference_bundle_v1__user-a': jsonEncode(sampleBundle()),
      'reference_bundle_v1__user-b': jsonEncode(sampleBundle()),
    });
    await ReferenceService(
      rpcClient: _FakeRpc(),
      currentUserId: () => 'user-a',
    ).clearAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('reference_bundle_v1__user-a'), isFalse);
    expect(prefs.containsKey('reference_bundle_v1__user-b'), isFalse);
  });
}
