import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'import_studio_item.dart';
import 'import_studio_repository.dart';

/// Supabase Admin repository for Stage 19 Import Studio.
///
/// RPC mapping (see `20260729153000_stage19_import_studio_foundation.sql`):
/// - [listDomains] → `admin_import_studio_list_domains()`
/// - [startDryRun] → `admin_import_studio_start_dry_run(p_domain, p_rows, p_file_name, p_batch_key)`
/// - [getDiff] → `admin_import_studio_get_diff(p_batch_id, p_classification, p_limit, p_offset)`
/// - [apply] → `admin_import_studio_apply(p_batch_id, p_confirm_batch_key)`
/// - [listBatches] → `admin_import_studio_list_batches(p_domain, p_limit)`
/// - [cancelBatch] → `admin_import_studio_cancel_batch(p_batch_id)`
/// - [rollbackBatch] → `admin_import_studio_rollback_batch(p_batch_id, p_confirm_batch_key)`
///
/// Delegated apply RPCs (called inside SQL, not from Dart directly):
/// - teachers → `admin_teacher_import_apply(jsonb)`
/// - subjects → `admin_subject_import_apply(jsonb)`
/// - students → `admin_student_import_apply(jsonb)`
///
/// **Remote safety:** this class performs RPC calls only. It does not bypass
/// RBAC or apply migrations. Use [LocalImportStudioRepository] for local
/// prototype / widget tests. Do not wire apply against remote without owner
/// approval and a local migration apply.
abstract class ImportStudioAdminRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseImportStudioAdminRpcClient implements ImportStudioAdminRpcClient {
  SupabaseImportStudioAdminRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class SupabaseImportStudioRepository implements ImportStudioRepository {
  SupabaseImportStudioRepository({
    SupabaseClient? client,
    ImportStudioAdminRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseImportStudioAdminRpcClient(
             client ?? Supabase.instance.client,
           );

  final ImportStudioAdminRpcClient _rpc;

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      throw _mapError(error);
    }
  }

  ImportStudioRepositoryException _mapError(PostgrestException error) {
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    if (code == '42501' || message.contains('forbidden')) {
      return const ImportStudioRepositoryException(
        'Недостаточно прав для этого действия.',
        code: 'forbidden',
        isForbidden: true,
      );
    }
    if (code == '28000' || message.contains('not_authenticated')) {
      return const ImportStudioRepositoryException(
        'Требуется вход. Войдите снова.',
        code: 'not_authenticated',
      );
    }
    if (code == 'P0002' || message.contains('not_found')) {
      return const ImportStudioRepositoryException(
        'Batch не найден.',
        code: 'not_found',
      );
    }
    if (message.contains('not_implemented_domain')) {
      return ImportStudioRepositoryException(
        error.message,
        code: 'not_implemented_domain',
      );
    }
    if (message.contains('apply_not_supported')) {
      return ImportStudioRepositoryException(
        'Apply не поддерживается для этого домена.',
        code: 'apply_not_supported',
      );
    }
    if (message.contains('batch_key_confirmation_mismatch')) {
      return const ImportStudioRepositoryException(
        'Ключ batch не совпадает.',
        code: 'batch_key_confirmation_mismatch',
      );
    }
    if (message.contains('could not find the function') || code == 'PGRST202') {
      return const ImportStudioRepositoryException(
        'Import Studio RPC ещё не применены (ожидается локальный apply миграции Stage 19).',
        code: 'rpc_missing',
      );
    }
    return ImportStudioRepositoryException(
      'Не удалось выполнить операцию Import Studio.',
      code: code.isEmpty ? null : code,
    );
  }

  dynamic _decode(dynamic data) {
    if (data is String && data.isNotEmpty) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return data;
      }
    }
    return data;
  }

  Map<String, dynamic> _asMap(dynamic data) {
    final value = _decode(data);
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const ImportStudioRepositoryException('Некорректный ответ сервера.');
  }

  List<Map<String, dynamic>> _asList(dynamic data) {
    final value = _decode(data);
    if (value is List) {
      return value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  @override
  Future<List<ImportStudioDomainInfo>> listDomains() async {
    final data = await _call('admin_import_studio_list_domains');
    return _asList(data).map(ImportStudioDomainInfo.fromJson).toList();
  }

  @override
  Future<ImportStudioBatch> startDryRun({
    required String domain,
    required List<Map<String, dynamic>> rows,
    String fileName = '',
    String? batchKey,
  }) async {
    final data = await _call('admin_import_studio_start_dry_run', {
      'p_domain': domain,
      'p_rows': rows,
      'p_file_name': fileName,
      'p_batch_key': batchKey,
    });
    return ImportStudioBatch.fromJson(_asMap(data));
  }

  @override
  Future<ImportStudioDiff> getDiff({
    required String batchId,
    String? classification,
    int limit = 200,
    int offset = 0,
  }) async {
    final data = await _call('admin_import_studio_get_diff', {
      'p_batch_id': batchId,
      'p_classification': classification,
      'p_limit': limit,
      'p_offset': offset,
    });
    final map = _asMap(data);
    final batch = ImportStudioBatch.fromJson(map);
    final rows = _asList(map['rows']).map(ImportStudioDiffRow.fromJson).toList();
    return ImportStudioDiff(batch: batch, rows: rows);
  }

  @override
  Future<ImportStudioBatch> apply({
    required String batchId,
    required String confirmBatchKey,
  }) async {
    final data = await _call('admin_import_studio_apply', {
      'p_batch_id': batchId,
      'p_confirm_batch_key': confirmBatchKey,
    });
    final map = _asMap(data);
    final batch = ImportStudioBatch.fromJson(map);
    if (map['delegated_apply_failed'] == true ||
        map['ok'] == false ||
        batch.status == ImportStudioBatchStatus.failed) {
      final detail = (map['detail'] ?? '').toString().trim();
      throw ImportStudioRepositoryException(
        detail.isEmpty
            ? 'Delegated apply отказал. Batch сохранён со статусом failed.'
            : 'Delegated apply отказал ($detail). Batch в статусе failed.',
        code: 'delegated_apply_failed',
      );
    }
    return batch;
  }

  @override
  Future<List<ImportStudioBatch>> listBatches({
    String? domain,
    int limit = 20,
  }) async {
    final data = await _call('admin_import_studio_list_batches', {
      'p_domain': domain,
      'p_limit': limit,
    });
    return _asList(data).map(ImportStudioBatch.fromJson).toList();
  }

  @override
  Future<ImportStudioBatch> cancelBatch(String batchId) async {
    final data = await _call('admin_import_studio_cancel_batch', {
      'p_batch_id': batchId,
    });
    return ImportStudioBatch.fromJson(_asMap(data));
  }

  @override
  Future<ImportStudioRollbackResult> rollbackBatch({
    required String batchId,
    required String confirmBatchKey,
  }) async {
    final data = await _call('admin_import_studio_rollback_batch', {
      'p_batch_id': batchId,
      'p_confirm_batch_key': confirmBatchKey,
    });
    return ImportStudioRollbackResult.fromJson(_asMap(data));
  }
}
