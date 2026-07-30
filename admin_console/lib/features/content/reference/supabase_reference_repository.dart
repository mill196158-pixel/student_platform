import 'dart:convert';

import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'reference_item.dart';
import 'reference_repository.dart';

/// Supabase Admin repository for reference articles/categories.
///
/// Primary RPC surface (Stage 16.3):
/// - `admin_list_reference_articles` / `admin_upsert_reference_article`
/// - `admin_list_reference_categories` / `admin_upsert_reference_category`
/// - `admin_reorder_reference_categories`
/// - `admin_list_content_corrections` / `admin_resolve_content_correction`
///
/// Audience publish/archive still reuse Stage 14 generic RPCs
/// (`admin_set_content_audience`, `admin_preview_content_audience`,
/// `admin_publish_content`, `admin_archive_content`) because they are
/// placement-agnostic.
abstract class ReferenceAdminRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseReferenceAdminRpcClient implements ReferenceAdminRpcClient {
  SupabaseReferenceAdminRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class SupabaseReferenceRepository implements ReferenceRepository {
  SupabaseReferenceRepository({
    SupabaseClient? client,
    ReferenceAdminRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseReferenceAdminRpcClient(client ?? Supabase.instance.client);

  final ReferenceAdminRpcClient _rpc;

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      throw _mapError(error);
    }
  }

  ReferenceRepositoryException _mapError(PostgrestException error) {
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    if (code == '42501' || message.contains('forbidden')) {
      return const ReferenceRepositoryException(
        'Недостаточно прав для этого действия.',
        isForbidden: true,
      );
    }
    if (code == '28000' || message.contains('not_authenticated')) {
      return const ReferenceRepositoryException(
        'Требуется вход. Войдите снова.',
      );
    }
    if (code == 'P0002' || message.contains('not_found')) {
      return const ReferenceRepositoryException('Запись не найдена.');
    }
    if (message.contains('row_version') || message.contains('conflict')) {
      return const ReferenceRepositoryException(
        'Данные изменились. Обновите список.',
      );
    }
    if (message.contains('could not find the function') || code == 'PGRST202') {
      return const ReferenceRepositoryException(
        'Reference RPC ещё не применены на remote (ожидается локальный apply).',
      );
    }
    return const ReferenceRepositoryException(
      'Не удалось выполнить операцию. Попробуйте ещё раз.',
    );
  }

  String _originWire(ContentOrigin origin) {
    switch (origin) {
      case ContentOrigin.demo:
        return 'demo';
      case ContentOrigin.admin:
        return 'admin';
      case ContentOrigin.importSource:
        return 'import';
      case ContentOrigin.userSubmission:
        return 'user_submission';
    }
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
        throw const ReferenceRepositoryException('Некорректный ответ сервера.');
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const ReferenceRepositoryException('Некорректный ответ сервера.');
  }

  ReferenceArticleItem _parseArticleRequired(dynamic data) {
    try {
      return ReferenceArticleItem.parseOrThrow(_asMap(data));
    } on FormatException catch (error) {
      throw ReferenceRepositoryException(error.message);
    }
  }

  ReferenceArticleItem _parseWorkingDraftResponse(dynamic data) {
    final map = _asMap(data);
    try {
      // Validate hard fields, then overlay working_draft when present.
      ReferenceArticleItem.parseOrThrow(map);
    } on FormatException catch (error) {
      throw ReferenceRepositoryException(error.message);
    }
    final item = ReferenceArticleItem.tryParseWithWorkingDraftOverlay(map);
    if (item == null) {
      throw const ReferenceRepositoryException('Некорректный ответ сервера.');
    }
    return item;
  }

  ReferenceCategoryItem _parseCategoryRequired(dynamic data) {
    final item = ReferenceCategoryItem.tryParse(_asMap(data));
    if (item == null) {
      throw const ReferenceRepositoryException('Некорректный ответ сервера.');
    }
    return item;
  }

  @override
  Future<List<ReferenceCategoryItem>> listCategories() async {
    final data = await _call('admin_list_reference_categories');
    return _asList(data)
        .map(ReferenceCategoryItem.tryParse)
        .whereType<ReferenceCategoryItem>()
        .toList();
  }

  @override
  Future<List<ReferenceArticleItem>> listArticles({String? status}) async {
    final data = await _call('admin_list_reference_articles', {
      'p_status': status,
    });
    return _asList(data)
        .map(ReferenceArticleItem.tryParse)
        .whereType<ReferenceArticleItem>()
        .toList();
  }

  @override
  Future<ReferenceCategoryItem> upsertCategory(
    ReferenceCategoryItem item,
  ) async {
    final data = await _call('admin_upsert_reference_category', {
      if (item.id.isNotEmpty) 'p_id': item.id,
      'p_expected_row_version': item.rowVersion,
      'p_patch': {
        'title': item.title,
        'icon_key': item.iconKey,
        'sort_order': item.sortOrder,
        'status': item.status.name,
        // Stable key is set only on create; server ignores mutations later.
        if (item.id.isEmpty && item.key != null) 'key': item.key,
      },
    });
    return _parseCategoryRequired(data);
  }

  @override
  Future<void> safeDeleteCategory({
    required String id,
    required int expectedRowVersion,
    required String mode,
    String? reassignToId,
  }) async {
    await _call('admin_safe_delete_reference_category', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
      'p_mode': mode,
      if (reassignToId != null && reassignToId.isNotEmpty)
        'p_reassign_to': reassignToId,
    });
  }

  @override
  Future<void> reorderCategories(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  ) async {
    await _call('admin_reorder_reference_categories', {
      'p_ordered_ids': orderedIds,
      'p_expected_row_versions': expectedRowVersions,
    });
  }

  @override
  Future<ReferenceArticleItem> createArticleDraft({
    required String title,
    required ReferenceArticlePayload payload,
    required String categoryId,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final data = await _call('admin_upsert_reference_article', {
      'p_patch': {
        'title': title,
        'origin': _originWire(origin),
        'reference_category_id': categoryId,
        'template_key': 'reference_article_v1',
        'schema_version': 2,
        'payload': payload.toWireJson(
          schemaVersion: 2,
        ), // create path default v2
        'sort_order': 0,
      },
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<ReferenceArticleItem> updateArticleDraft(
    ReferenceArticleItem item,
  ) async {
    final data = await _call('admin_upsert_reference_article', {
      'p_id': item.id,
      'p_expected_row_version': item.rowVersion,
      'p_patch': {
        'title': item.title,
        'origin': _originWire(item.origin),
        'reference_category_id': item.categoryId,
        'payload': item.payload.toWireJson(
          schemaVersion: item.effectiveSchemaVersion,
        ),
        'sort_order': item.sortOrder,
      },
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<ReferenceArticleItem> setArticleSortOrder({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final data = await _call('admin_upsert_reference_article', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
      'p_patch': {'sort_order': sortOrder},
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<ReferenceArticleItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  }) async {
    final data = await _call('admin_set_content_audience', {
      'p_id': id,
      'p_mode': audienceMode,
      'p_group_ids': groupIds,
      'p_user_ids': userIds,
      'p_expected_row_version': expectedRowVersion,
    });
    // Stage 16.3 wraps the RPC to return reference_article_admin_json.
    // Fall back to list refetch if a pre-wrap response lacks category fields.
    final parsed = ReferenceArticleItem.tryParse(_asMap(data));
    if (parsed != null) return parsed;
    final listed = await listArticles();
    for (final article in listed) {
      if (article.id == id) return article;
    }
    throw StateError(
      'Reference audience save succeeded but article $id missing',
    );
  }

  @override
  Future<ReferenceAudiencePreview> previewAudience(String id) async {
    final data = await _call('admin_preview_content_audience', {'p_id': id});
    return ReferenceAudiencePreview.fromJson(_asMap(data));
  }

  @override
  Future<ReferenceArticleItem> publish(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_publish_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<ReferenceArticleItem> unpublish(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_unpublish_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<ReferenceArticleItem> archive(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_archive_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<ReferenceArticleItem> unarchive(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_unarchive_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<void> safeDelete(String id, int expectedRowVersion) async {
    await _call('admin_safe_delete_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
  }

  @override
  Future<ReferenceArticleItem> promoteDemo(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_promote_demo_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<List<ReferenceVersionInfo>> listVersions(String id) async {
    final data = await _call('admin_list_content_versions', {'p_id': id});
    return _asList(data).map(ReferenceVersionInfo.fromJson).toList();
  }

  @override
  Future<ReferenceArticleItem> restoreVersion(
    String id,
    int versionNumber,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_restore_content_version', {
      'p_id': id,
      'p_version_number': versionNumber,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseArticleRequired(data);
  }

  @override
  Future<List<ReferenceCorrectionItem>> listCorrections({
    String status = 'open',
  }) async {
    final data = await _call('admin_list_content_corrections', {
      'p_status': status,
    });
    return _asList(data)
        .map(ReferenceCorrectionItem.tryParse)
        .whereType<ReferenceCorrectionItem>()
        .toList();
  }

  @override
  Future<void> resolveCorrection({
    required String id,
    required String action,
    String reason = '',
  }) async {
    await _call('admin_resolve_content_correction', {
      'p_id': id,
      'p_action': action,
      'p_reason': reason,
    });
  }

  @override
  Future<ReferenceArticleItem> beginEdit(String id) async {
    final data = await _call('admin_begin_content_edit', {'p_id': id});
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<ReferenceArticleItem> saveWorkingDraft(
    ReferenceArticleItem item, {
    required int expectedDraftRowVersion,
  }) async {
    final data = await _call('admin_save_content_working_draft', {
      'p_id': item.id,
      'p_expected_draft_row_version': expectedDraftRowVersion,
      'p_patch': item.toWorkingDraftPatch(),
    });
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<ReferenceArticleItem> publishWorkingDraft(
    String id, {
    required int expectedDraftRowVersion,
  }) async {
    final data = await _call('admin_publish_content_working_draft', {
      'p_id': id,
      'p_expected_draft_row_version': expectedDraftRowVersion,
    });
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<ReferenceArticleItem> discardWorkingDraft(String id) async {
    final data = await _call('admin_discard_content_working_draft', {
      'p_id': id,
    });
    return _parseWorkingDraftResponse(data);
  }
}
