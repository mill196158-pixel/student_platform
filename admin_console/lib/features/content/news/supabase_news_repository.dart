import 'dart:convert';

import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'news_item.dart';
import 'news_repository.dart';

/// Thin RPC boundary so tests can inject a fake without a live Supabase client.
abstract class NewsRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseNewsRpcClient implements NewsRpcClient {
  SupabaseNewsRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

/// News repository backed by RBAC-gated `SECURITY DEFINER` RPCs.
///
/// Never logs tokens or URLs; only reads/writes via named RPCs.
class SupabaseNewsRepository implements NewsRepository {
  SupabaseNewsRepository({SupabaseClient? client, NewsRpcClient? rpcClient})
    : _rpc =
          rpcClient ??
          SupabaseNewsRpcClient(client ?? Supabase.instance.client);

  final NewsRpcClient _rpc;

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      throw _mapError(error);
    }
  }

  NewsRepositoryException _mapError(PostgrestException error) {
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    if (code == '42501' || message.contains('forbidden')) {
      return const NewsRepositoryException(
        'Недостаточно прав для этого действия.',
        isForbidden: true,
      );
    }
    if (code == '28000' || message.contains('not_authenticated')) {
      return const NewsRepositoryException('Требуется вход. Войдите снова.');
    }
    if (code == 'P0002' || message.contains('not_found')) {
      return const NewsRepositoryException('Новость не найдена.');
    }
    if (message.contains('archived_immutable')) {
      return const NewsRepositoryException('Архивную новость нельзя изменить.');
    }
    return NewsRepositoryException(
      'Не удалось выполнить операцию. Попробуйте ещё раз.',
    );
  }

  List<Map<String, dynamic>> _asList(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const [];
      }
    }
    if (value is List) {
      return value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Map<String, dynamic> _asMap(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        throw const NewsRepositoryException('Некорректный ответ сервера.');
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const NewsRepositoryException('Некорректный ответ сервера.');
  }

  @override
  Future<List<NewsItem>> listNews() async {
    final data = await _call('admin_list_news');
    return _asList(data).map(NewsItem.fromJson).toList();
  }

  @override
  Future<List<NewsItem>> loadDraft() => listNews();

  @override
  Future<NewsItem> createDraft({
    String title = '',
    String subtitle = '',
    String body = '',
    StudentHomeNewsVariant variant = StudentHomeNewsVariant.gradientText,
  }) async {
    final data = await _call('admin_create_news_draft', {
      'p_title': title,
      'p_subtitle': subtitle,
      'p_body': body,
      'p_variant': variant.label,
    });
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsItem> updateDraft(NewsItem item) async {
    final data = await _call('admin_update_news_draft', {
      'p_id': item.id,
      'p_patch': item.toPatchJson(),
    });
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsItem> publish(String id) async {
    final data = await _call('admin_publish_news', {'p_id': id});
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsItem> unpublish(String id) async {
    final data = await _call('admin_unpublish_news', {'p_id': id});
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsItem> archive(String id) async {
    final data = await _call('admin_archive_news', {'p_id': id});
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsItem> duplicate(String id) async {
    final data = await _call('admin_duplicate_news', {'p_id': id});
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<void> reorder(List<String> orderedIds) async {
    await _call('admin_reorder_news', {'p_ordered_ids': orderedIds});
  }

  @override
  Future<List<NewsVersionInfo>> listVersions(String id) async {
    final data = await _call('admin_list_news_versions', {'p_id': id});
    return _asList(data).map(NewsVersionInfo.fromJson).toList();
  }

  @override
  Future<NewsItem> restoreVersion(String id, int versionNumber) async {
    final data = await _call('admin_restore_news_version', {
      'p_id': id,
      'p_version_number': versionNumber,
    });
    return NewsItem.fromJson(_asMap(data));
  }
}
