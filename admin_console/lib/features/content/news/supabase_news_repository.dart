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
    if (message.contains('news_must_be_archived')) {
      return const NewsRepositoryException(
        'Окончательное удаление и восстановление доступны только для архивных новостей.',
      );
    }
    if (code == 'PGRST202' ||
        code == '42883' ||
        message.contains('could not find the function')) {
      return const NewsRepositoryException(
        'RPC недоступен на этом backend (ожидается local apply Stage 15.2). '
        'Multi-group/user аудитория отключена fail-closed.',
      );
    }
    if (message.contains('use_admin_set_news_audience')) {
      return const NewsRepositoryException(
        'Аудиторию меняйте через отдельный контроль Stage 15.2.',
      );
    }
    if (message.contains('draft_only')) {
      return const NewsRepositoryException(
        'Аудиторию можно менять только у черновика.',
      );
    }
    if (message.contains('version_conflict')) {
      return const NewsRepositoryException(
        'Новость изменилась. Обновите список.',
      );
    }
    return const NewsRepositoryException(
      'Не удалось выполнить операцию. Попробуйте ещё раз.',
    );
  }

  List<String> _asStringList(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
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
  Future<NewsItem> getNews(String id) async {
    final data = await _call('admin_get_news', {'p_id': id});
    return NewsItem.fromJson(_asMap(data));
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
  Future<NewsItem> updateDraft(
    NewsItem item, {
    NewsImagePathPatch imagePathPatch = NewsImagePathPatch.omit,
  }) async {
    final data = await _call('admin_update_news_draft', {
      'p_id': item.id,
      'p_patch': item.toPatchJson(imagePathPatch: imagePathPatch),
    });
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsItem> setAudience({
    required String id,
    required NewsAudienceMode mode,
    List<String> groupIds = const [],
    List<String> userIds = const [],
    required int expectedVersion,
  }) async {
    try {
      final data = await _call('admin_set_news_audience', {
        'p_id': id,
        'p_mode': newsAudienceModeWire(mode),
        'p_expected_version': expectedVersion,
        'p_group_ids': groupIds,
        'p_user_ids': userIds,
      });
      return NewsItem.fromJson(_asMap(data));
    } on NewsRepositoryException catch (error) {
      // Fail-closed dual-read: only legacy all / single-group may fall back
      // through admin_update_news_draft when Stage 15.2 RPCs are absent.
      if (!_looksLikeMissingRpc(error.message)) rethrow;
      return _legacyAudienceFallback(
        id: id,
        mode: mode,
        groupIds: groupIds,
        userIds: userIds,
      );
    }
  }

  bool _looksLikeMissingRpc(String message) {
    final m = message.toLowerCase();
    return m.contains('rpc недоступен') ||
        m.contains('could not find the function') ||
        m.contains('local apply');
  }

  Future<NewsItem> _legacyAudienceFallback({
    required String id,
    required NewsAudienceMode mode,
    required List<String> groupIds,
    required List<String> userIds,
  }) async {
    if (mode == NewsAudienceMode.users ||
        mode == NewsAudienceMode.groupsAndUsers ||
        (mode == NewsAudienceMode.groups && groupIds.length != 1) ||
        userIds.isNotEmpty) {
      throw const NewsRepositoryException(
        'Расширенная аудитория недоступна на этом backend '
        '(ожидается local apply Stage 15.2). '
        'Доступны только legacy «все» или одна группа.',
      );
    }
    final data = await _call('admin_update_news_draft', {
      'p_id': id,
      'p_patch': {
        'audience_type': mode == NewsAudienceMode.all ? 'all' : 'group',
        'audience_group_id':
            mode == NewsAudienceMode.all ? '' : groupIds.first,
      },
    });
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsAudiencePreview> previewAudience(String id) async {
    try {
      final data = await _call('admin_preview_news_audience', {'p_id': id});
      return NewsAudiencePreview.fromJson(_asMap(data));
    } on NewsRepositoryException {
      rethrow;
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('could not find the function') ||
          message.contains('pgrst202')) {
        throw const NewsRepositoryException(
          'Preview аудитории недоступен: RPC Stage 15.2 не применён.',
        );
      }
      rethrow;
    }
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
  Future<NewsItem> restoreArchived(String id) async {
    final data = await _call('admin_restore_archived_news', {'p_id': id});
    return NewsItem.fromJson(_asMap(data));
  }

  @override
  Future<NewsDeleteResult> deleteArchived(String id) async {
    final data = await _call('admin_delete_archived_news', {'p_post_id': id});
    final map = _asMap(data);
    return NewsDeleteResult(
      id: (map['id'] ?? id).toString(),
      title: (map['title'] ?? '').toString(),
      previousStatus: NewsStatus.archived,
      candidateMediaPaths: _asStringList(map['candidate_media_paths']),
      mediaPathsToDelete: _asStringList(map['media_paths_to_delete']),
    );
  }

  @override
  Future<void> recordMediaCleanupFailure({
    required List<String> paths,
    String? sourceNewsPostId,
    String? sourceTitle,
    String? errorText,
  }) async {
    if (paths.isEmpty) return;
    await _call('admin_record_news_media_cleanup_failure', {
      'p_paths': paths,
      'p_source_news_post_id': sourceNewsPostId,
      'p_source_title': sourceTitle,
      'p_error_text': errorText,
    });
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
