import 'dart:convert';

import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_promo_item.dart';
import 'home_promo_repository.dart';
import '../shared/content_action_model.dart';

abstract class HomePromoRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseHomePromoRpcClient implements HomePromoRpcClient {
  SupabaseHomePromoRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class SupabaseHomePromoRepository implements HomePromoRepository {
  SupabaseHomePromoRepository({
    SupabaseClient? client,
    HomePromoRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseHomePromoRpcClient(client ?? Supabase.instance.client);

  final HomePromoRpcClient _rpc;

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      throw _mapError(error);
    }
  }

  HomePromoRepositoryException _mapError(PostgrestException error) {
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    if (code == '42501' || message.contains('forbidden')) {
      return const HomePromoRepositoryException(
        'Недостаточно прав для этого действия.',
        isForbidden: true,
      );
    }
    if (code == '28000' || message.contains('not_authenticated')) {
      return const HomePromoRepositoryException(
        'Требуется вход. Войдите снова.',
      );
    }
    if (code == 'P0002' || message.contains('not_found')) {
      return const HomePromoRepositoryException('Карточка не найдена.');
    }
    if (message.contains('row_version') || message.contains('conflict')) {
      return const HomePromoRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    if (message.contains('visual_studio_v2_publish_disabled')) {
      return const HomePromoRepositoryException(
        kVisualStudioV2PublishBlockedMessageRu,
      );
    }
    if (message.contains('could not find the function') || code == 'PGRST202') {
      return const HomePromoRepositoryException(
        'Managed content RPC ещё не применены на remote (ожидается локальный apply).',
      );
    }
    return const HomePromoRepositoryException(
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

  HomePromoItem _parseRequired(dynamic data) {
    final map = _asMap(data);
    final item = HomePromoItem.tryParse(map);
    if (item == null) {
      throw const HomePromoRepositoryException('Некорректный ответ сервера.');
    }
    return item;
  }

  HomePromoItem _parseWorkingDraftResponse(dynamic data) {
    final map = _asMap(data);
    final item = HomePromoItem.tryParseWithWorkingDraftOverlay(map);
    if (item == null) {
      throw const HomePromoRepositoryException('Некорректный ответ сервера.');
    }
    return item;
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
        throw const HomePromoRepositoryException('Некорректный ответ сервера.');
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const HomePromoRepositoryException('Некорректный ответ сервера.');
  }

  @override
  Future<List<HomePromoItem>> list({String? status}) async {
    final data = await _call('admin_list_content_items', {
      'p_status': status,
      'p_placement': 'home_promo',
      'p_origin': null,
    });
    return _asList(
      data,
    ).map(HomePromoItem.tryParse).whereType<HomePromoItem>().toList();
  }

  @override
  Future<HomePromoItem> createDraft({
    required HomePromoPayload payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final data = await _call('admin_create_content_draft', {
      'p_template_key': 'home_promo_v1',
      'p_schema_version': 2,
      'p_title': title ?? payload.title,
      'p_payload': payload.toWireJson(),
      'p_origin': _originWire(origin),
    });
    final created = _parseRequired(data);
    return setPlacements(
      id: created.id,
      sortOrder: 0,
      expectedRowVersion: created.rowVersion,
    );
  }

  @override
  Future<HomePromoItem> updateDraft(HomePromoItem item) async {
    final data = await _call('admin_update_content_draft', {
      'p_id': item.id,
      'p_expected_row_version': item.rowVersion,
      'p_patch': {
        'title': item.title,
        'payload': item.payload.toWireJson(),
        'priority': item.priority,
        'starts_at': item.startsAt?.toUtc().toIso8601String(),
        'ends_at': item.endsAt?.toUtc().toIso8601String(),
        'origin': _originWire(item.origin),
      },
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final data = await _call('admin_set_content_placements', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
      'p_placements': [
        {'placement': 'home_promo', 'sort_order': sortOrder},
      ],
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> setAudience({
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
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> publish(String id, int expectedRowVersion) async {
    final data = await _call('admin_publish_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> archive(String id, int expectedRowVersion) async {
    final data = await _call('admin_archive_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> unpublish(String id, int expectedRowVersion) async {
    final data = await _call('admin_unpublish_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> restoreArchived(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_unarchive_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoSafeDeleteResult> safeDelete(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_safe_delete_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return HomePromoSafeDeleteResult.fromJson(_asMap(data));
  }

  @override
  Future<HomePromoItem> duplicate(String id) async {
    final data = await _call('admin_duplicate_content', {'p_id': id});
    return _parseRequired(data);
  }

  @override
  Future<HomePromoItem> promoteDemo(String id, int expectedRowVersion) async {
    final data = await _call('admin_promote_demo_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<List<HomePromoVersionInfo>> listVersions(String id) async {
    final data = await _call('admin_list_content_versions', {'p_id': id});
    return _asList(data).map(HomePromoVersionInfo.fromJson).toList();
  }

  @override
  Future<HomePromoItem> restoreVersion(String id, int versionNumber) async {
    final current = await list();
    final item = current.cast<HomePromoItem?>().firstWhere(
      (e) => e?.id == id,
      orElse: () => null,
    );
    if (item == null) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    final data = await _call('admin_restore_content_version', {
      'p_id': id,
      'p_version_number': versionNumber,
      'p_expected_row_version': item.rowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<HomePromoAudiencePreview> previewAudience(String id) async {
    final data = await _call('admin_preview_content_audience', {'p_id': id});
    return HomePromoAudiencePreview.fromJson(_asMap(data));
  }

  @override
  Future<void> reorder(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  ) async {
    await _call('admin_reorder_content_placement', {
      'p_placement': 'home_promo',
      'p_ordered_ids': orderedIds,
      'p_expected_row_versions': expectedRowVersions,
    });
  }

  @override
  Future<HomePromoItem> beginEdit(String id) async {
    final data = await _call('admin_begin_content_edit', {'p_id': id});
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<HomePromoItem> saveWorkingDraft(
    HomePromoItem item, {
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
  Future<HomePromoItem> publishWorkingDraft(
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
  Future<HomePromoItem> discardWorkingDraft(String id) async {
    final data = await _call('admin_discard_content_working_draft', {
      'p_id': id,
    });
    return _parseWorkingDraftResponse(data);
  }
}
