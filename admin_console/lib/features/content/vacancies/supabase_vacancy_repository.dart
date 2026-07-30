import 'dart:convert';
import 'dart:typed_data';

import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'vacancy_item.dart';
import 'vacancy_media_store.dart';
import 'vacancy_repository.dart';

/// Supabase Admin repository for Stage 17 vacancies domain.
///
/// RPC mapping (see `20260729151000_stage17_vacancies_domain.sql`):
/// - [list] → `admin_list_vacancies(p_status, p_origin, p_limit, p_offset)`
/// - [get] → `admin_get_vacancy(p_id)`
/// - [createDraft] → `admin_create_vacancy_draft(p_patch, p_origin)`
/// - [updateDraft] → `admin_update_vacancy_draft(p_id, p_patch, p_expected_row_version)`
/// - [setAudience] → `admin_set_vacancy_audience(...)`
/// - [previewAudience] → `admin_preview_vacancy_audience(p_id)`
/// - [publish] → `admin_publish_vacancy(p_id, p_expected_row_version)`
abstract class VacancyAdminRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseVacancyAdminRpcClient implements VacancyAdminRpcClient {
  SupabaseVacancyAdminRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class SupabaseVacancyRepository implements VacancyRepository {
  SupabaseVacancyRepository({
    SupabaseClient? client,
    VacancyAdminRpcClient? rpcClient,
    VacancyMediaStore? mediaStore,
  }) : _rpc =
           rpcClient ??
           SupabaseVacancyAdminRpcClient(client ?? Supabase.instance.client),
       _mediaStore = mediaStore;

  final VacancyAdminRpcClient _rpc;
  final VacancyMediaStore? _mediaStore;

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      throw _mapError(error);
    }
  }

  VacancyRepositoryException _mapError(PostgrestException error) {
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    if (code == '42501' || message.contains('forbidden')) {
      return const VacancyRepositoryException(
        'Недостаточно прав для этого действия.',
        isForbidden: true,
      );
    }
    if (code == '28000' || message.contains('not_authenticated')) {
      return const VacancyRepositoryException('Требуется вход. Войдите снова.');
    }
    if (code == 'P0002' || message.contains('not_found')) {
      return const VacancyRepositoryException('Вакансия не найдена.');
    }
    if (message.contains('row_version') || message.contains('conflict')) {
      return const VacancyRepositoryException(
        'Вакансия изменилась. Обновите список.',
      );
    }
    if (message.contains('could not find the function') || code == 'PGRST202') {
      return const VacancyRepositoryException(
        'Vacancies RPC ещё не применены на remote (ожидается локальный apply).',
      );
    }
    return const VacancyRepositoryException(
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

  VacancyItem _parseRequired(dynamic data) {
    final map = _asMap(data);
    final item = VacancyItem.tryParse(map);
    if (item == null) {
      throw const VacancyRepositoryException('Некорректный ответ сервера.');
    }
    return item;
  }

  VacancyItem _parseWorkingDraftResponse(dynamic data) {
    final map = _asMap(data);
    final item = VacancyItem.tryParseWithWorkingDraftOverlay(map);
    if (item == null) {
      throw const VacancyRepositoryException('Некорректный ответ сервера.');
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
        throw const VacancyRepositoryException('Некорректный ответ сервера.');
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const VacancyRepositoryException('Некорректный ответ сервера.');
  }

  @override
  Future<List<VacancyItem>> list({String? status, String? origin}) async {
    final data = await _call('admin_list_vacancies', {
      'p_status': status,
      'p_origin': origin,
      'p_limit': 100,
      'p_offset': 0,
    });
    return _asList(
      data,
    ).map(VacancyItem.tryParse).whereType<VacancyItem>().toList();
  }

  @override
  Future<VacancyItem> get(String id) async {
    final data = await _call('admin_get_vacancy', {'p_id': id});
    return _parseRequired(data);
  }

  @override
  Future<VacancyItem> createDraft({
    required VacancyItem draft,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final data = await _call('admin_create_vacancy_draft', {
      'p_patch': draft.toDraftPatch(),
      'p_origin': _originWire(origin),
    });
    return _parseRequired(data);
  }

  @override
  Future<VacancyItem> updateDraft(VacancyItem item) async {
    final data = await _call('admin_update_vacancy_draft', {
      'p_id': item.id,
      'p_patch': item.toDraftPatch(),
      'p_expected_row_version': item.rowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<VacancyItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  }) async {
    final data = await _call('admin_set_vacancy_audience', {
      'p_id': id,
      'p_mode': audienceMode,
      'p_group_ids': groupIds,
      'p_user_ids': userIds,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<VacancyAudiencePreview> previewAudience(String id) async {
    final data = await _call('admin_preview_vacancy_audience', {'p_id': id});
    return VacancyAudiencePreview.fromJson(_asMap(data));
  }

  @override
  Future<VacancyItem> publish(String id, int expectedRowVersion) async {
    final data = await _call('admin_publish_vacancy', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<VacancyItem> promoteDemo(String id, int expectedRowVersion) async {
    final data = await _call('admin_promote_demo_vacancy', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
    return _parseRequired(data);
  }

  @override
  Future<void> safeDelete(String id, int expectedRowVersion) async {
    await _call('admin_safe_delete_vacancy', {
      'p_id': id,
      'p_expected_row_version': expectedRowVersion,
    });
  }

  @override
  Future<VacancyItem> moderate({
    required String id,
    required String action,
    required int expectedRowVersion,
    String? reason,
  }) async {
    final data = await _call('admin_moderate_vacancy', {
      'p_id': id,
      'p_action': action,
      'p_expected_row_version': expectedRowVersion,
      'p_reason': reason ?? '',
    });
    return _parseRequired(data);
  }

  @override
  Future<VacancyItem> setLifecycle({
    required String id,
    required String action,
    required int expectedRowVersion,
    String? reason,
  }) async {
    final data = await _call('admin_set_vacancy_lifecycle', {
      'p_id': id,
      'p_action': action,
      'p_expected_row_version': expectedRowVersion,
      'p_reason': reason ?? '',
    });
    return _parseRequired(data);
  }

  @override
  Future<List<VacancyVersionEntry>> listVersions(String id) async {
    final data = await _call('admin_list_vacancy_versions', {'p_id': id});
    return _asList(
      data,
    ).map(VacancyVersionEntry.fromJson).where((e) => e.id.isNotEmpty).toList();
  }

  @override
  Future<List<VacancyModerationEntry>> listModerationActions(String id) async {
    final data = await _call('admin_list_vacancy_moderation_actions', {
      'p_id': id,
      'p_limit': 50,
    });
    return _asList(data).map(VacancyModerationEntry.fromJson).toList();
  }

  @override
  Future<List<VacancyReportEntry>> listReports({String status = 'open'}) async {
    final data = await _call('admin_list_vacancy_reports', {
      'p_status': status,
      'p_limit': 50,
    });
    return _asList(data).map(VacancyReportEntry.fromJson).toList();
  }

  @override
  Future<void> resolveReport({
    required String reportId,
    required String action,
    String? reason,
  }) async {
    await _call('admin_resolve_vacancy_report', {
      'p_report_id': reportId,
      'p_action': action,
      'p_reason': reason ?? '',
    });
  }

  @override
  Future<String> registerAsset({
    required String vacancyId,
    required List<int> bytes,
    required String contentType,
    String title = '',
  }) async {
    final store = _mediaStore ?? VacancyMediaStore();
    return store.uploadBytes(
      vacancyId: vacancyId,
      bytes: Uint8List.fromList(bytes),
      contentType: contentType,
      title: title,
    );
  }

  @override
  Future<void> deleteAsset(String assetId) async {
    await _call('admin_delete_vacancy_asset', {'p_asset_id': assetId});
  }

  @override
  Future<VacancyItem> beginEdit(String id) async {
    final data = await _call('admin_begin_vacancy_edit', {'p_id': id});
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<VacancyItem> saveWorkingDraft(
    VacancyItem item, {
    required int expectedDraftRowVersion,
  }) async {
    final data = await _call('admin_save_vacancy_working_draft', {
      'p_id': item.id,
      'p_expected_draft_row_version': expectedDraftRowVersion,
      'p_patch': item.toWorkingDraftPatch(),
    });
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<VacancyItem> publishWorkingDraft(
    String id, {
    required int expectedDraftRowVersion,
  }) async {
    final data = await _call('admin_publish_vacancy_working_draft', {
      'p_id': id,
      'p_expected_draft_row_version': expectedDraftRowVersion,
    });
    return _parseWorkingDraftResponse(data);
  }

  @override
  Future<VacancyItem> discardWorkingDraft(String id) async {
    final data = await _call('admin_discard_vacancy_working_draft', {
      'p_id': id,
    });
    return _parseWorkingDraftResponse(data);
  }
}
