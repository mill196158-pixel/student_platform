import 'dart:convert';

import 'import_studio_item.dart';

class ImportStudioRepositoryException implements Exception {
  const ImportStudioRepositoryException(
    this.message, {
    this.code,
    this.isForbidden = false,
  });

  final String message;
  final String? code;
  final bool isForbidden;

  @override
  String toString() => message;
}

abstract class ImportStudioRepository {
  Future<List<ImportStudioDomainInfo>> listDomains();

  Future<ImportStudioBatch> startDryRun({
    required String domain,
    required List<Map<String, dynamic>> rows,
    String fileName = '',
    String? batchKey,
  });

  Future<ImportStudioDiff> getDiff({
    required String batchId,
    String? classification,
    int limit = 200,
    int offset = 0,
  });

  Future<ImportStudioBatch> apply({
    required String batchId,
    required String confirmBatchKey,
  });

  Future<List<ImportStudioBatch>> listBatches({
    String? domain,
    int limit = 20,
  });

  Future<ImportStudioBatch> cancelBatch(String batchId);

  Future<ImportStudioRollbackResult> rollbackBatch({
    required String batchId,
    required String confirmBatchKey,
  });
}

/// In-memory Import Studio repository for local prototype / unit tests.
///
/// Mirrors the Stage 19 RPC contract:
/// `admin_import_studio_list_domains`, `admin_import_studio_start_dry_run`,
/// `admin_import_studio_get_diff`, `admin_import_studio_apply`, etc.
class LocalImportStudioRepository implements ImportStudioRepository {
  LocalImportStudioRepository();

  final Map<String, _LocalBatchRecord> _batches = {};
  int _batchSeq = 1;

  /// Test hook: next [apply] persists `failed` and throws `delegated_apply_failed`.
  bool failNextApply = false;

  static const _allDomains = [
    'teachers',
    'subjects',
    'students',
    'groups',
    'curriculum',
    'terms',
    'offerings',
    'teacher_links',
    'enrollments',
  ];

  @override
  Future<List<ImportStudioDomainInfo>> listDomains() async {
    return [
      for (final domain in _allDomains) _domainInfo(domain, localMode: true),
    ];
  }

  @override
  Future<ImportStudioBatch> startDryRun({
    required String domain,
    required List<Map<String, dynamic>> rows,
    String fileName = '',
    String? batchKey,
  }) async {
    final normalizedDomain = domain.trim();
    if (importStudioDomainStateFor(normalizedDomain) ==
        ImportStudioDomainState.notImplemented) {
      throw ImportStudioRepositoryException(
        'Домен $normalizedDomain ещё не реализован (not_implemented_domain_$normalizedDomain).',
        code: 'not_implemented_domain_$normalizedDomain',
      );
    }
    if (rows.isEmpty) {
      throw const ImportStudioRepositoryException(
        'Нужна хотя бы одна строка для dry-run.',
        code: 'empty_rows',
      );
    }

    final hash = _payloadHash(normalizedDomain, rows);
    final key = (batchKey?.trim().isNotEmpty == true) ? batchKey!.trim() : hash;

    final existing = _findByKey(normalizedDomain, key);
    if (existing != null && existing.batch.status == ImportStudioBatchStatus.applied) {
      if (existing.payloadHash != hash) {
        throw const ImportStudioRepositoryException(
          'Batch с этим batch_key уже применён с другим содержимым.',
          code: 'batch_key_payload_mismatch',
        );
      }
      return existing.batch.copyWith(alreadyApplied: true);
    }

    final diffRows = _validateRows(normalizedDomain, rows);
    final summary = _summarize(diffRows);
    final batchId = existing?.batch.batchId ?? 'local-batch-${_batchSeq++}';

    final batch = ImportStudioBatch(
      batchId: batchId,
      domain: normalizedDomain,
      status: ImportStudioBatchStatus.dryRun,
      batchKey: key,
      fileName: fileName,
      rowCount: summary.total,
      errorCount: summary.errorCount,
      summary: summary,
      domainState: importStudioDomainStateFor(normalizedDomain),
      supportsApply:
          importStudioDomainStateFor(normalizedDomain) ==
          ImportStudioDomainState.apply,
    );

    _batches[batchId] = _LocalBatchRecord(
      batch: batch,
      rows: diffRows,
      payloadHash: hash,
    );
    return batch;
  }

  @override
  Future<ImportStudioDiff> getDiff({
    required String batchId,
    String? classification,
    int limit = 200,
    int offset = 0,
  }) async {
    final record = _requireBatch(batchId);
    var rows = record.rows;
    if (classification != null && classification.isNotEmpty) {
      rows = rows
          .where((row) => row.classification.wire == classification)
          .toList();
    }
    final slice = rows.skip(offset).take(limit).toList();
    return ImportStudioDiff(batch: record.batch, rows: slice);
  }

  @override
  Future<ImportStudioBatch> apply({
    required String batchId,
    required String confirmBatchKey,
  }) async {
    final record = _requireBatch(batchId);
    final batch = record.batch;

    if (confirmBatchKey.trim() != batch.batchKey) {
      throw const ImportStudioRepositoryException(
        'Ключ batch не совпадает. Подтвердите точный batch_key.',
        code: 'batch_key_confirmation_mismatch',
      );
    }

    if (batch.status == ImportStudioBatchStatus.applied) {
      return batch.copyWith(alreadyApplied: true, idempotentReplay: true);
    }
    if (batch.status != ImportStudioBatchStatus.dryRun) {
      throw const ImportStudioRepositoryException(
        'Batch нельзя применить в текущем статусе.',
        code: 'batch_not_appliable',
      );
    }
    if (!batch.supportsApply) {
      throw ImportStudioRepositoryException(
        'Apply не поддерживается для домена ${batch.domain}.',
        code: 'apply_not_supported_for_domain_${batch.domain}',
      );
    }
    if (batch.errorCount > 0) {
      throw const ImportStudioRepositoryException(
        'Dry-run содержит ошибки. Исправьте строки перед apply.',
        code: 'batch_has_errors',
      );
    }

    if (failNextApply) {
      failNextApply = false;
      final failed = batch.copyWith(status: ImportStudioBatchStatus.failed);
      _batches[batchId] = record.copyWith(batch: failed);
      throw const ImportStudioRepositoryException(
        'Delegated apply отказал. Batch сохранён со статусом failed.',
        code: 'delegated_apply_failed',
      );
    }

    final applied = batch.copyWith(
      status: ImportStudioBatchStatus.applied,
      alreadyApplied: false,
    );
    _batches[batchId] = record.copyWith(batch: applied);
    return applied;
  }

  @override
  Future<List<ImportStudioBatch>> listBatches({
    String? domain,
    int limit = 20,
  }) async {
    final items = _batches.values
        .map((record) => record.batch)
        .where((batch) => domain == null || batch.domain == domain)
        .toList()
      ..sort((a, b) => b.batchId.compareTo(a.batchId));
    return items.take(limit).toList();
  }

  @override
  Future<ImportStudioBatch> cancelBatch(String batchId) async {
    final record = _requireBatch(batchId);
    if (record.batch.status != ImportStudioBatchStatus.dryRun) {
      throw const ImportStudioRepositoryException(
        'Отменить можно только dry-run batch.',
        code: 'batch_not_cancellable',
      );
    }
    final cancelled = record.batch.copyWith(
      status: ImportStudioBatchStatus.cancelled,
    );
    _batches[batchId] = record.copyWith(batch: cancelled);
    return cancelled;
  }

  @override
  Future<ImportStudioRollbackResult> rollbackBatch({
    required String batchId,
    required String confirmBatchKey,
  }) async {
    final record = _requireBatch(batchId);
    final batch = record.batch;

    if (confirmBatchKey.trim() != batch.batchKey) {
      throw const ImportStudioRepositoryException(
        'Ключ batch не совпадает.',
        code: 'batch_key_confirmation_mismatch',
      );
    }
    if (batch.status != ImportStudioBatchStatus.applied) {
      throw const ImportStudioRepositoryException(
        'Откат доступен только для applied batch.',
        code: 'batch_not_applied',
      );
    }

    return ImportStudioRollbackResult(
      ok: false,
      refused: true,
      batchId: batchId,
      domain: batch.domain,
      rollbackSafe: false,
      errorCode: 'rollback_not_supported_for_batch',
      message:
          'Откат batch для домена ${batch.domain} пока не поддерживается. Журнал отказа записан.',
    );
  }

  ImportStudioDomainInfo _domainInfo(String domain, {required bool localMode}) {
    final state = importStudioDomainStateFor(domain);
    return ImportStudioDomainInfo(
      domain: domain,
      label: importStudioDomainLabel(domain),
      domainState: state,
      applyPermission: importStudioDomainPermissions[domain] ?? '',
      supportsApply: state == ImportStudioDomainState.apply,
      templateColumns: importStudioTemplateColumns[domain] ?? const [],
      canDryRun: state != ImportStudioDomainState.notImplemented,
      canApply: state == ImportStudioDomainState.apply,
      notes: importStudioDomainNotes(domain),
    );
  }

  _LocalBatchRecord _requireBatch(String batchId) {
    final record = _batches[batchId];
    if (record == null) {
      throw const ImportStudioRepositoryException(
        'Batch не найден.',
        code: 'not_found',
      );
    }
    return record;
  }

  _LocalBatchRecord? _findByKey(String domain, String batchKey) {
    for (final record in _batches.values) {
      if (record.batch.domain == domain && record.batch.batchKey == batchKey) {
        return record;
      }
    }
    return null;
  }

  String _payloadHash(String domain, List<Map<String, dynamic>> rows) {
    return md5Like('$domain:${jsonEncode(rows)}');
  }

  List<ImportStudioDiffRow> _validateRows(
    String domain,
    List<Map<String, dynamic>> rows,
  ) {
    final allowed = importStudioTemplateColumns[domain] ?? const [];
    final seen = <String>{};
    final diffRows = <ImportStudioDiffRow>[];

    for (var i = 0; i < rows.length; i++) {
      final source = Map<String, dynamic>.from(rows[i]);
      final errors = <String>[];
      final unknown = source.keys
          .where(
            (k) =>
                !allowed.contains(k) &&
                k != 'contacts_public' &&
                !(domain == 'teachers' && k == 'public_email'),
          )
          .toList();
      if (unknown.isNotEmpty) {
        errors.add('unknown_columns:${unknown.join(',')}');
      }

      final mapped = _mapDelegatedPayload(domain, source);

      var classification = ImportStudioRowClassification.newRow;
      String? dedupeKey;

      switch (domain) {
        case 'teachers':
          final teacherId = '${source['teacher_id'] ?? ''}'.trim();
          if (teacherId.isNotEmpty) {
            dedupeKey = teacherId.toLowerCase();
            classification = ImportStudioRowClassification.update;
          } else {
            dedupeKey = _norm('${source['full_name'] ?? ''}');
            if (dedupeKey.isEmpty) errors.add('full_name_required');
          }
        case 'subjects':
          final subjectId = '${source['subject_id'] ?? ''}'.trim();
          if (subjectId.isNotEmpty) {
            dedupeKey = subjectId.toLowerCase();
            classification = ImportStudioRowClassification.update;
          } else {
            dedupeKey = _norm('${source['canonical_name'] ?? ''}');
            if (dedupeKey.isEmpty) errors.add('canonical_name_required');
          }
        case 'students':
          dedupeKey = '${source['login'] ?? ''}'.trim().toLowerCase();
          if (dedupeKey.isEmpty) errors.add('login_required');
        case 'groups':
          dedupeKey = _norm('${source['name'] ?? ''}');
          if (dedupeKey.isEmpty) errors.add('name_required');
        case 'curriculum':
          dedupeKey = _norm(
            '${source['group_name'] ?? ''}|${source['subject_name'] ?? ''}|${source['semester_number'] ?? ''}',
          );
          if (_norm('${source['group_name'] ?? ''}').isEmpty) {
            errors.add('group_name_required');
          }
          if (_norm('${source['subject_name'] ?? ''}').isEmpty) {
            errors.add('subject_name_required');
          }
          if ('${source['semester_number'] ?? ''}'.trim().isEmpty) {
            errors.add('semester_number_required');
          }
        case 'terms':
          dedupeKey = _norm(
            '${source['academic_year_name'] ?? ''}|${source['name'] ?? ''}',
          );
          if (source.containsKey('is_current')) {
            errors.add('current_term_flip_forbidden');
          }
          if (_norm('${source['name'] ?? ''}').isEmpty) {
            errors.add('name_required');
          }
          if (_norm('${source['academic_year_name'] ?? ''}').isEmpty) {
            errors.add('academic_year_name_required');
          }
      }

      if (dedupeKey != null && dedupeKey.isNotEmpty) {
        if (seen.contains(dedupeKey)) {
          classification = ImportStudioRowClassification.duplicate;
        } else {
          seen.add(dedupeKey);
        }
      }

      if (errors.isNotEmpty) {
        classification = ImportStudioRowClassification.error;
      }

      diffRows.add(
        ImportStudioDiffRow(
          rowNumber: i + 1,
          classification: classification,
          sourcePayload: source,
          mappedPayload: mapped,
          errorText: errors.isEmpty ? null : errors.join(','),
        ),
      );
    }
    return diffRows;
  }

  ImportStudioBatchSummary _summarize(List<ImportStudioDiffRow> rows) {
    var newCount = 0;
    var updateCount = 0;
    var duplicateCount = 0;
    var errorCount = 0;
    for (final row in rows) {
      switch (row.classification) {
        case ImportStudioRowClassification.newRow:
          newCount++;
        case ImportStudioRowClassification.update:
          updateCount++;
        case ImportStudioRowClassification.duplicate:
          duplicateCount++;
        case ImportStudioRowClassification.error:
          errorCount++;
        case ImportStudioRowClassification.skip:
          break;
      }
    }
    return ImportStudioBatchSummary(
      total: rows.length,
      newCount: newCount,
      updateCount: updateCount,
      duplicateCount: duplicateCount,
      errorCount: errorCount,
    );
  }

  String _norm(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  Map<String, dynamic> _mapDelegatedPayload(
    String domain,
    Map<String, dynamic> source,
  ) {
    switch (domain) {
      case 'teachers':
        final contacts = <String, dynamic>{};
        if (source['contacts_public'] is Map) {
          contacts.addAll(
            Map<String, dynamic>.from(source['contacts_public'] as Map),
          );
        }
        final publicEmail = (source['public_email'] ?? source['email'] ?? '')
            .toString()
            .trim();
        if (publicEmail.isNotEmpty) contacts['public_email'] = publicEmail;
        for (final key in const ['website', 'office', 'telegram']) {
          final value = (source[key] ?? '').toString().trim();
          if (value.isNotEmpty) contacts[key] = value;
        }
        final teacherId = (source['teacher_id'] ?? '').toString().trim();
        return {
          if (teacherId.isNotEmpty) 'teacher_id': teacherId,
          if ((source['full_name'] ?? '').toString().trim().isNotEmpty)
            'full_name': source['full_name'],
          if ((source['department'] ?? '').toString().trim().isNotEmpty)
            'department': source['department'],
          if ((source['position'] ?? '').toString().trim().isNotEmpty)
            'position': source['position'],
          if ((source['academic_degree'] ?? '').toString().trim().isNotEmpty)
            'academic_degree': source['academic_degree'],
          if ((source['about_text'] ?? '').toString().trim().isNotEmpty)
            'about_text': source['about_text'],
          if (publicEmail.isNotEmpty) 'public_email': publicEmail,
          if (contacts.isNotEmpty) 'contacts_public': contacts,
        };
      case 'subjects':
        return {
          for (final key in const [
            'subject_id',
            'canonical_name',
            'description',
            'department',
            'control_form',
            'difficulty_label',
            'requirements',
            'learning_outcomes',
            'short_description',
            'what_to_expect',
            'how_to_pass',
            'useful_materials_note',
            'common_pitfalls',
          ])
            if ((source[key] ?? '').toString().trim().isNotEmpty) key: source[key],
          if (source['useful_links'] is List && (source['useful_links'] as List).isNotEmpty)
            'useful_links': source['useful_links'],
        };
      default:
        final allowed = importStudioTemplateColumns[domain] ?? const [];
        final mapped = <String, dynamic>{};
        for (final column in allowed) {
          final value = source[column];
          if (value != null && '$value'.trim().isNotEmpty) {
            mapped[column] = value;
          }
        }
        return mapped;
    }
  }
}

class _LocalBatchRecord {
  const _LocalBatchRecord({
    required this.batch,
    required this.rows,
    required this.payloadHash,
  });

  final ImportStudioBatch batch;
  final List<ImportStudioDiffRow> rows;
  final String payloadHash;

  _LocalBatchRecord copyWith({
    ImportStudioBatch? batch,
    List<ImportStudioDiffRow>? rows,
    String? payloadHash,
  }) {
    return _LocalBatchRecord(
      batch: batch ?? this.batch,
      rows: rows ?? this.rows,
      payloadHash: payloadHash ?? this.payloadHash,
    );
  }
}

extension on ImportStudioBatch {
  ImportStudioBatch copyWith({
    ImportStudioBatchStatus? status,
    bool? alreadyApplied,
    bool? idempotentReplay,
  }) {
    return ImportStudioBatch(
      batchId: batchId,
      domain: domain,
      status: status ?? this.status,
      batchKey: batchKey,
      fileName: fileName,
      rowCount: rowCount,
      errorCount: errorCount,
      summary: summary,
      domainState: domainState,
      supportsApply: supportsApply,
      alreadyApplied: alreadyApplied ?? this.alreadyApplied,
      idempotentReplay: idempotentReplay ?? this.idempotentReplay,
      rollbackSafe: rollbackSafe,
    );
  }
}

/// Lightweight deterministic hash for local idempotency keys (not crypto).
String md5Like(String input) {
  var hash = 0;
  for (final codeUnit in input.codeUnits) {
    hash = (hash * 31 + codeUnit) & 0x7fffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
