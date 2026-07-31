import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile_feed_item.dart';
import 'profile_feed_repository.dart';
import '../shared/visual_editor_operation_error.dart';

abstract class ProfileFeedAdminRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseProfileFeedAdminRpcClient implements ProfileFeedAdminRpcClient {
  SupabaseProfileFeedAdminRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class SupabaseProfileFeedRepository implements ProfileFeedRepository {
  SupabaseProfileFeedRepository({
    SupabaseClient? client,
    ProfileFeedAdminRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseProfileFeedAdminRpcClient(
             client ?? Supabase.instance.client,
           );

  final ProfileFeedAdminRpcClient _rpc;

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      throw _mapError(error);
    }
  }

  ProfileFeedRepositoryException _mapError(PostgrestException error) {
    final mapped = mapVisualEditorOperationError(error);
    if ((error.code == 'PGRST202') ||
        (error.message.toLowerCase().contains('could not find the function'))) {
      return const ProfileFeedRepositoryException(
        'Managed content RPC ещё не применены на remote (ожидается локальный apply).',
      );
    }
    return ProfileFeedRepositoryException(
      mapped.message,
      isForbidden: mapped.isForbidden,
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

  ProfileFeedItem _parseRequired(dynamic data) {
    final map = _asMap(data);
    final item = ProfileFeedItem.tryParse(map);
    if (item == null) {
      throw const ProfileFeedRepositoryException('Некорректный ответ сервера.');
    }
    return item;
  }

  ProfileFeedItem _parseWorkingDraftResponse(dynamic data) {
    final map = _asMap(data);
    final item = ProfileFeedItem.tryParseWithWorkingDraftOverlay(map);
    if (item == null) {
      throw const ProfileFeedRepositoryException('Некорректный ответ сервера.');
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
        throw const ProfileFeedRepositoryException(
          'Некорректный ответ сервера.',
        );
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const ProfileFeedRepositoryException('Некорректный ответ сервера.');
  }

  @override
  Future<List<ProfileFeedItem>> list({String? status}) async {
    final data = await _call('admin_list_content_items', {
      'p_status': status,
      'p_placement': 'profile_feed',
      'p_origin': null,
    });
    return _asList(
      data,
    ).map(ProfileFeedItem.tryParse).whereType<ProfileFeedItem>().toList();
  }

  @override
  Future<ProfileFeedItem> createDraft({
    ProfileFeedPayload? payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final basePayload =
        payload ??
        ProfileFeedPayload(
          title: 'Новая карточка',
          subtitle: 'Краткое описание',
          ctaLabel: 'Открыть',
          iconKey: 'info',
          gradientColors: const [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
          cardVariant: 'gradient_text',
          gradientAngle: 45,
          ctaRoute: '/profile',
        );
    final data = await _call('admin_create_content_draft', {
      'p_template_key': 'profile_feed_card_v1',
      'p_schema_version': 2,
      'p_title': title ?? basePayload.title,
      'p_payload': basePayload.toWireJson(),
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
  Future<ProfileFeedItem> updateDraft(ProfileFeedItem item) async {
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
  Future<ProfileFeedItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final data = await _call('admin_set_content_placements', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
      'p_placements': [
        {'placement': 'profile_feed', 'sort_order': sortOrder},
      ],
    });
    return _parseRequired(data);
  }

  @override
  Future<ProfileFeedItem> setAudience({
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
  Future<ProfileFeedAudiencePreview> previewAudience(String id) async {
    final data = await _call('admin_preview_content_audience', {'p_id': id});
    return ProfileFeedAudiencePreview.fromJson(_asMap(data));
  }

  @override
  Future<ProfileFeedItem> publish(String id, int expectedRowVersion) async {
    final data = await _call('admin_publish_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<ProfileFeedItem> archive(String id, int expectedRowVersion) async {
    final data = await _call('admin_archive_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<ProfileFeedItem> unpublish(String id, int expectedRowVersion) async {
    final data = await _call('admin_unpublish_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<ProfileFeedItem> restoreArchived(
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
  Future<ProfileFeedDeleteResult> safeDelete(
    String id,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_safe_delete_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return ProfileFeedDeleteResult.fromJson(_asMap(data));
  }

  @override
  Future<ProfileFeedItem> duplicate(String id) async {
    final data = await _call('admin_duplicate_content', {'p_id': id});
    return _parseRequired(data);
  }

  @override
  Future<ProfileFeedItem> promoteDemo(String id, int expectedRowVersion) async {
    final data = await _call('admin_promote_demo_content', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<List<ProfileFeedVersionInfo>> listVersions(String id) async {
    final data = await _call('admin_list_content_versions', {'p_id': id});
    return _asList(data).map(ProfileFeedVersionInfo.fromJson).toList();
  }

  @override
  Future<ProfileFeedItem> restoreVersion(
    String id,
    int versionNumber,
    int expectedRowVersion,
  ) async {
    final data = await _call('admin_restore_content_version', {
      'p_id': id,
      'p_version_number': versionNumber,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<void> reorder(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  ) async {
    await _call('admin_reorder_content_placement', {
      'p_placement': 'profile_feed',
      'p_ordered_ids': orderedIds,
      'p_expected_row_versions': expectedRowVersions,
    });
  }

  @override
  Future<ProfileFeedItem> beginEdit(String id) async {
    final data = await _call('admin_begin_content_edit', {'p_id': id});
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<ProfileFeedItem> saveWorkingDraft(
    ProfileFeedItem item, {
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
  Future<ProfileFeedItem> publishWorkingDraft(
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
  Future<ProfileFeedItem> discardWorkingDraft(String id) async {
    final data = await _call('admin_discard_content_working_draft', {
      'p_id': id,
    });
    return _parseWorkingDraftResponse(data);
  }
}
