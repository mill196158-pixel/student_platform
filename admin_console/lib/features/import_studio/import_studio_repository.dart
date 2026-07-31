import 'dart:convert';

import 'package:meta/meta.dart';

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
  int _entitySeq = 1;

  /// Test hook: next [apply] persists `failed` and throws `delegated_apply_failed`.
  bool failNextApply = false;

  /// Test hook: the entity id a given applied row created/matched (parallel
  /// to `getDiff`'s row order). The real RPC surfaces this via
  /// `matched_term_id` / `matched_curriculum_subject_id` / etc. on
  /// `import_studio_rows`; exposed here only so tests can drive an
  /// id-provided follow-up row (e.g. to exercise post-apply drift) without
  /// reaching into private state.
  @visibleForTesting
  String? debugAppliedEntityId({required String batchId, required int rowIndex}) {
    final record = _batches[batchId];
    if (record == null) return null;
    if (rowIndex < 0 || rowIndex >= record.appliedEntityIds.length) return null;
    return record.appliedEntityIds[rowIndex];
  }

  // --- In-memory "world" state, mirroring the referential entities the
  // Stage 19 completion migration writes to (groups, academic_terms,
  // curriculum_subjects, subject_offerings, offering_teachers,
  // student_enrollments). Lets id-first matching, warnings, and rollback
  // dependency checks behave the same way locally as against real SQL. ---
  final Map<String, String> _groupIdByName = {}; // normalized name -> id
  final Map<String, String> _groupNameById = {};

  final Map<String, String> _termIdByKey = {}; // "year|name" -> id
  final Map<String, String> _termNameById = {};

  final Map<String, String> _curriculumIdByKey = {}; // "subject|semester"
  final Set<String> _curriculumIds = {};

  final Map<String, String> _offeringIdByKey = {}; // "group|subject|term"
  final Set<String> _offeringIds = {};

  final Map<String, String> _teacherLinkIdByKey = {}; // "offering|teacher|role"

  final Map<String, String> _activeEnrollmentGroupByLogin = {};
  final Map<String, String> _enrollmentIdByKey = {}; // "login|group"

  // Rollback dependency tracking mirroring
  // private.import_studio_{term,curriculum,offering}_blockers. Live
  // reference sets (not one-way flags) so a blocker clears once its last
  // referencing row is itself rolled back — same as the SQL blockers, which
  // re-query the table at rollback time instead of caching "ever had one".
  final Map<String, Set<String>> _offeringsByTermId = {};
  final Map<String, String> _offeringTermId = {};
  final Map<String, Set<String>> _offeringsByCurriculumId = {};
  final Map<String, String> _offeringCurriculumId = {};
  final Map<String, Set<String>> _teacherLinksByOfferingId = {};
  final Map<String, String> _teacherLinkOfferingId = {};

  String _newEntityId(String prefix) => '$prefix-${_entitySeq++}';

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
    final summary = _summarize(normalizedDomain, diffRows);
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
      appliedEntityIds: List<String?>.filled(diffRows.length, null),
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

    final outcome = _applyDomainSideEffects(batch.domain, record.rows);
    final applied = batch.copyWith(
      status: ImportStudioBatchStatus.applied,
      alreadyApplied: false,
      rollbackSafe: importStudioRollbackSafeDomains.contains(batch.domain),
    );
    _batches[batchId] = record.copyWith(
      batch: applied,
      appliedEntityIds: outcome.appliedEntityIds,
      applyCreated: outcome.createdFlags,
      applyRowFingerprint: outcome.fingerprints,
    );
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

    if (!importStudioRollbackSafeDomains.contains(batch.domain)) {
      return ImportStudioRollbackResult(
        ok: false,
        refused: true,
        batchId: batchId,
        domain: batch.domain,
        rollbackSafe: false,
        errorCode: 'rollback_not_supported_for_batch',
        message:
            'Откат batch для домена ${batch.domain} не поддерживается: изменения могут быть '
            'связаны с другими данными (team/chat, зачисления, ручные правки после импорта).',
      );
    }

    // P1: a batch that touched ANY pre-existing row (matched/updated rather
    // than created by THIS apply call) is refused wholesale rather than
    // partially rolled back — there is no before-snapshot to restore an
    // updated row to. applyCreated (recorded atomically at apply time) is
    // authoritative here, not the dry-run classification, which could go
    // stale under a dry-run/apply race. Mirrors
    // admin_import_studio_rollback_batch's rollback_refused_has_updates gate.
    final appliedRowIndexes = [
      for (var i = 0; i < record.rows.length; i++)
        if ((record.rows[i].classification == ImportStudioRowClassification.newRow ||
                record.rows[i].classification == ImportStudioRowClassification.update) &&
            record.appliedEntityIds[i] != null)
          i,
    ];
    final updateCount = appliedRowIndexes
        .where((i) => record.applyCreated[i] != true)
        .length;
    if (updateCount > 0) {
      return ImportStudioRollbackResult(
        ok: false,
        refused: true,
        batchId: batchId,
        domain: batch.domain,
        rollbackSafe: true,
        errorCode: 'rollback_refused_has_updates',
        message:
            'Откат отклонён: этот batch обновил $updateCount уже существующих записей — снимок '
            '«до» не хранится, поэтому откат мог бы исказить данные, которые batch не создавал.',
      );
    }

    final newRowIndexes = [
      for (final i in appliedRowIndexes)
        if (record.applyCreated[i] == true) i,
    ];

    // Dependency check FIRST, over every row this rollback would touch —
    // never a partial undo, mirroring the nested-subtransaction SQL rollback.
    for (final i in newRowIndexes) {
      final blocker = _rollbackBlockerFor(batch.domain, record.appliedEntityIds[i]!);
      if (blocker != null) {
        return ImportStudioRollbackResult(
          ok: false,
          refused: true,
          batchId: batchId,
          domain: batch.domain,
          rollbackSafe: true,
          errorCode: 'rollback_blocked_by_dependency',
          message: 'Откат отклонён: rollback_blocked_by_dependency:$blocker',
        );
      }
    }

    // P1: drift check, also over every row before deleting any of them —
    // refuse (never silently delete) if the live entity no longer matches
    // the fingerprint captured at apply time (e.g. a later admin edit),
    // mirroring the SQL migration's apply_row_fingerprint comparison. A
    // missing fingerprint (recorded before this safety net existed) is
    // treated as drift too, since there is nothing to prove it did not.
    for (final i in newRowIndexes) {
      final id = record.appliedEntityIds[i]!;
      final expected = record.applyRowFingerprint[i];
      final live = _currentFingerprint(batch.domain, id);
      if (expected == null || live != expected) {
        return ImportStudioRollbackResult(
          ok: false,
          refused: true,
          batchId: batchId,
          domain: batch.domain,
          rollbackSafe: true,
          errorCode: 'rollback_refused_row_drift',
          message:
              'Откат отклонён: rollback_refused_row_drift:${batch.domain}:$id',
        );
      }
    }

    for (final i in newRowIndexes.reversed) {
      _deleteEntity(batch.domain, record.appliedEntityIds[i]!);
    }
    final deleted = newRowIndexes.length;
    // Always 0: the updateCount check above already refused the whole
    // rollback if any row in this batch matched/updated a pre-existing row
    // instead of being created by this apply call.
    const updatesNotReverted = 0;

    final rolledBack = batch.copyWith(status: ImportStudioBatchStatus.rolledBack);
    _batches[batchId] = record.copyWith(batch: rolledBack);

    return ImportStudioRollbackResult(
      ok: true,
      refused: false,
      batchId: batchId,
      domain: batch.domain,
      rollbackSafe: true,
      errorCode: '',
      message:
          'Откат выполнен: удалено $deleted новых записей. Обновления существующих записей '
          '($updatesNotReverted шт.) не откатываются — снимок «до» не хранится.',
      deletedCount: deleted,
      updatesNotReverted: updatesNotReverted,
    );
  }

  /// Applies domain-specific world-state writes for a just-confirmed batch,
  /// mirroring `private.import_studio_apply_*` in the completion migration.
  /// Returns, per row, the entity id this row created/matched (or `null` for
  /// domains without local world-state, and for rows that weren't applied)
  /// alongside whether THIS apply call actually created that entity (as
  /// opposed to matching a pre-existing one) — mirrors the SQL migration's
  /// `apply_created` column, which is set atomically at apply time and is
  /// what rollback actually deletes by, never the dry-run classification.
  _ApplyOutcome _applyDomainSideEffects(
    String domain,
    List<ImportStudioDiffRow> rows,
  ) {
    final appliedIds = List<String?>.filled(rows.length, null);
    final created = List<bool>.filled(rows.length, false);
    final fingerprints = List<String?>.filled(rows.length, null);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.classification != ImportStudioRowClassification.newRow &&
          row.classification != ImportStudioRowClassification.update) {
        continue;
      }
      switch (domain) {
        case 'groups':
          final (id, isNew) = _applyGroupRow(row.sourcePayload);
          appliedIds[i] = id;
          created[i] = isNew;
        case 'curriculum':
          final (id, isNew) = _applyCurriculumRow(row.sourcePayload);
          appliedIds[i] = id;
          created[i] = isNew;
        case 'terms':
          final (id, isNew) = _applyTermRow(row.sourcePayload);
          appliedIds[i] = id;
          created[i] = isNew;
        case 'offerings':
          final (id, isNew) = _applyOfferingRow(row.sourcePayload);
          appliedIds[i] = id;
          created[i] = isNew;
        case 'teacher_links':
          final (id, isNew) = _applyTeacherLinkRow(row.sourcePayload);
          appliedIds[i] = id;
          created[i] = isNew;
        case 'enrollments':
          final (id, isNew) = _applyEnrollmentRow(row.sourcePayload);
          appliedIds[i] = id;
          created[i] = isNew;
      }
      // P1: capture the apply-time fingerprint the instant this row's
      // entity was actually created (never for a matched/updated one),
      // mirroring apply_row_fingerprint in the SQL migration — rollback
      // recomputes and compares this before deleting, so a row that
      // drifted after apply is never silently destroyed.
      if (created[i] && appliedIds[i] != null) {
        fingerprints[i] = _currentFingerprint(domain, appliedIds[i]!);
      }
    }
    return _ApplyOutcome(appliedIds, created, fingerprints);
  }

  /// Mirrors `apply_row_fingerprint` in the SQL migration: a snapshot of the
  /// mutable content rollback would otherwise assume is untouched since
  /// apply. Only covers the fields this local world-state actually allows to
  /// drift (e.g. a term's name via a later `term_id`-keyed update row).
  String _currentFingerprint(String domain, String id) {
    switch (domain) {
      case 'terms':
        return 'name=${_termNameById[id] ?? ''}';
      case 'curriculum':
        return 'id=$id';
      case 'offerings':
        return 'term=${_offeringTermId[id] ?? ''}|curriculum=${_offeringCurriculumId[id] ?? ''}';
      case 'teacher_links':
        return 'offering=${_teacherLinkOfferingId[id] ?? ''}';
      default:
        return '';
    }
  }

  (String, bool) _applyGroupRow(Map<String, dynamic> source) {
    final groupId = '${source['group_id'] ?? ''}'.trim();
    final name = '${source['name'] ?? ''}'.trim();
    final normName = _norm(name);
    if (groupId.isNotEmpty) {
      final oldName = _groupNameById[groupId];
      if (oldName != null) _groupIdByName.remove(_norm(oldName));
      _groupNameById[groupId] = name;
      if (normName.isNotEmpty) _groupIdByName[normName] = groupId;
      return (groupId, false);
    }
    final existing = _groupIdByName[normName];
    if (existing != null) {
      _groupNameById[existing] = name;
      return (existing, false);
    }
    final id = _newEntityId('group');
    _groupNameById[id] = name;
    _groupIdByName[normName] = id;
    return (id, true);
  }

  (String, bool) _applyCurriculumRow(Map<String, dynamic> source) {
    final curriculumId = '${source['curriculum_subject_id'] ?? ''}'.trim();
    if (curriculumId.isNotEmpty) return (curriculumId, false);
    final key =
        '${_norm('${source['subject_name'] ?? ''}')}|${'${source['semester_number'] ?? ''}'.trim()}';
    final existing = _curriculumIdByKey[key];
    if (existing != null) return (existing, false);
    final id = _newEntityId('curriculum');
    _curriculumIds.add(id);
    _curriculumIdByKey[key] = id;
    return (id, true);
  }

  (String, bool) _applyTermRow(Map<String, dynamic> source) {
    final termId = '${source['term_id'] ?? ''}'.trim();
    final name = '${source['name'] ?? ''}'.trim();
    if (termId.isNotEmpty) {
      _termNameById[termId] = name;
      return (termId, false);
    }
    final key =
        '${_norm('${source['academic_year_name'] ?? ''}')}|${_norm(name)}';
    final existing = _termIdByKey[key];
    if (existing != null) {
      _termNameById[existing] = name;
      return (existing, false);
    }
    final id = _newEntityId('term');
    _termNameById[id] = name;
    _termIdByKey[key] = id;
    return (id, true);
  }

  (String?, bool) _applyOfferingRow(Map<String, dynamic> source) {
    final offeringId = '${source['offering_id'] ?? ''}'.trim();
    final groupName = _norm('${source['group_name'] ?? ''}');
    final subjectName = _norm('${source['subject_name'] ?? ''}');
    final yearName = _norm('${source['academic_year_name'] ?? ''}');
    final termName = _norm('${source['term_name'] ?? ''}');
    final termId = _termIdByKey['$yearName|$termName'];

    if (offeringId.isNotEmpty) {
      if (termId != null) {
        _offeringsByTermId.putIfAbsent(termId, () => {}).add(offeringId);
        _offeringTermId[offeringId] = termId;
      }
      return (offeringId, false);
    }
    if (termId == null) return (null, false);

    final curriculumKey =
        '$subjectName|${'${source['semester_number'] ?? ''}'.trim()}';
    final curriculumId = _curriculumIdByKey[curriculumKey];

    final key = '$groupName|$subjectName|$termId';
    final existing = _offeringIdByKey[key];
    final isNew = existing == null;
    final id = existing ?? _newEntityId('offering');
    if (existing == null) {
      _offeringIds.add(id);
      _offeringIdByKey[key] = id;
    }

    _offeringsByTermId.putIfAbsent(termId, () => {}).add(id);
    _offeringTermId[id] = termId;
    if (curriculumId != null) {
      _offeringsByCurriculumId.putIfAbsent(curriculumId, () => {}).add(id);
      _offeringCurriculumId[id] = curriculumId;
    }
    return (id, isNew);
  }

  (String?, bool) _applyTeacherLinkRow(Map<String, dynamic> source) {
    final linkId = '${source['teacher_link_id'] ?? ''}'.trim();
    var offeringId = '${source['offering_id'] ?? ''}'.trim();
    final teacherName = _norm(
      '${source['teacher_full_name'] ?? source['teacher_id'] ?? ''}',
    );
    final role = '${source['role'] ?? ''}'.trim();

    if (offeringId.isEmpty) {
      final groupName = _norm('${source['group_name'] ?? ''}');
      final subjectName = _norm('${source['subject_name'] ?? ''}');
      final yearName = _norm('${source['academic_year_name'] ?? ''}');
      final termName = _norm('${source['term_name'] ?? ''}');
      final termId = _termIdByKey['$yearName|$termName'];
      if (termId == null) return (null, false);
      offeringId = _offeringIdByKey['$groupName|$subjectName|$termId'] ?? '';
    }
    if (offeringId.isEmpty) return (null, false);

    if (linkId.isNotEmpty) {
      _teacherLinksByOfferingId.putIfAbsent(offeringId, () => {}).add(linkId);
      _teacherLinkOfferingId[linkId] = offeringId;
      return (linkId, false);
    }
    final key = '$offeringId|$teacherName|$role';
    final existing = _teacherLinkIdByKey[key];
    final isNew = existing == null;
    final id = existing ?? _newEntityId('teacher_link');
    if (existing == null) _teacherLinkIdByKey[key] = id;
    _teacherLinksByOfferingId.putIfAbsent(offeringId, () => {}).add(id);
    _teacherLinkOfferingId[id] = offeringId;
    return (id, isNew);
  }

  (String?, bool) _applyEnrollmentRow(Map<String, dynamic> source) {
    final enrollmentId = '${source['enrollment_id'] ?? ''}'.trim();
    final login = '${source['login'] ?? ''}'.trim().toLowerCase();
    final groupName = _norm('${source['group_name'] ?? ''}');
    if (enrollmentId.isNotEmpty) {
      _activeEnrollmentGroupByLogin[login] = groupName;
      return (enrollmentId, false);
    }
    final key = '$login|$groupName';
    final existing = _enrollmentIdByKey[key];
    _activeEnrollmentGroupByLogin[login] = groupName;
    if (existing != null) return (existing, false);
    final id = _newEntityId('enrollment');
    _enrollmentIdByKey[key] = id;
    return (id, true);
  }

  /// Mirrors `private.import_studio_{term,curriculum,offering}_blockers` —
  /// a live existence check against current references, not a cached flag.
  String? _rollbackBlockerFor(String domain, String id) {
    switch (domain) {
      case 'terms':
        if (_offeringsByTermId[id]?.isNotEmpty == true) return 'subject_offerings';
      case 'curriculum':
        if (_offeringsByCurriculumId[id]?.isNotEmpty == true) return 'subject_offerings';
      case 'offerings':
        if (_teacherLinksByOfferingId[id]?.isNotEmpty == true) return 'offering_teachers';
    }
    return null;
  }

  void _deleteEntity(String domain, String id) {
    switch (domain) {
      case 'terms':
        _termNameById.remove(id);
        _termIdByKey.removeWhere((_, value) => value == id);
        _offeringsByTermId.remove(id);
      case 'curriculum':
        _curriculumIds.remove(id);
        _curriculumIdByKey.removeWhere((_, value) => value == id);
        _offeringsByCurriculumId.remove(id);
      case 'offerings':
        _offeringIds.remove(id);
        _offeringIdByKey.removeWhere((_, value) => value == id);
        final termId = _offeringTermId.remove(id);
        if (termId != null) _offeringsByTermId[termId]?.remove(id);
        final curriculumId = _offeringCurriculumId.remove(id);
        if (curriculumId != null) _offeringsByCurriculumId[curriculumId]?.remove(id);
        _teacherLinksByOfferingId.remove(id);
      case 'teacher_links':
        _teacherLinkIdByKey.removeWhere((_, value) => value == id);
        final offeringId = _teacherLinkOfferingId.remove(id);
        if (offeringId != null) _teacherLinksByOfferingId[offeringId]?.remove(id);
    }
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
          final groupId = '${source['group_id'] ?? ''}'.trim();
          if (groupId.isNotEmpty) {
            if (!_groupNameById.containsKey(groupId)) {
              errors.add('group_id_not_found');
            } else {
              classification = ImportStudioRowClassification.update;
            }
            dedupeKey = groupId;
          } else {
            final name = _norm('${source['name'] ?? ''}');
            if (name.isEmpty) {
              errors.add('name_required');
            } else if (_groupIdByName.containsKey(name)) {
              classification = ImportStudioRowClassification.update;
            }
            dedupeKey = name;
          }
        case 'curriculum':
          final curriculumId = '${source['curriculum_subject_id'] ?? ''}'
              .trim();
          final groupName = _norm('${source['group_name'] ?? ''}');
          final subjectName = _norm('${source['subject_name'] ?? ''}');
          final semester = '${source['semester_number'] ?? ''}'.trim();
          if (groupName.isEmpty) {
            errors.add('group_name_required');
          } else if (!_groupIdByName.containsKey(groupName)) {
            errors.add('group_not_found');
          }
          if (subjectName.isEmpty) errors.add('subject_name_required');
          if (semester.isEmpty) errors.add('semester_number_required');
          if (curriculumId.isNotEmpty) {
            if (!_curriculumIds.contains(curriculumId)) {
              errors.add('curriculum_subject_id_not_found');
            } else {
              classification = ImportStudioRowClassification.update;
            }
            dedupeKey = curriculumId;
          } else {
            dedupeKey = '$subjectName|$semester';
            if (_curriculumIdByKey.containsKey(dedupeKey)) {
              classification = ImportStudioRowClassification.update;
            }
          }
        case 'terms':
          final termId = '${source['term_id'] ?? ''}'.trim();
          final yearName = _norm('${source['academic_year_name'] ?? ''}');
          final name = _norm('${source['name'] ?? ''}');
          if (source.containsKey('is_current')) {
            errors.add('current_term_flip_forbidden');
          }
          if (name.isEmpty) errors.add('name_required');
          if (yearName.isEmpty) errors.add('academic_year_name_required');
          if (termId.isNotEmpty) {
            if (!_termNameById.containsKey(termId)) {
              errors.add('term_id_not_found');
            } else {
              classification = ImportStudioRowClassification.update;
            }
            dedupeKey = termId;
          } else {
            dedupeKey = '$yearName|$name';
            if (_termIdByKey.containsKey(dedupeKey)) {
              classification = ImportStudioRowClassification.update;
            }
          }
        case 'offerings':
          final offeringId = '${source['offering_id'] ?? ''}'.trim();
          final groupName = _norm('${source['group_name'] ?? ''}');
          final subjectName = _norm('${source['subject_name'] ?? ''}');
          final yearName = _norm('${source['academic_year_name'] ?? ''}');
          final termName = _norm('${source['term_name'] ?? ''}');
          final semester = '${source['semester_number'] ?? ''}'.trim();
          String? termId;
          if (groupName.isEmpty) errors.add('group_name_required');
          if (!_groupIdByName.containsKey(groupName) && groupName.isNotEmpty) {
            errors.add('group_not_found');
          }
          if (subjectName.isEmpty) errors.add('subject_name_required');
          if (yearName.isEmpty) errors.add('academic_year_name_required');
          if (termName.isEmpty) errors.add('term_name_required');
          if (yearName.isNotEmpty && termName.isNotEmpty) {
            termId = _termIdByKey['$yearName|$termName'];
            if (termId == null) errors.add('term_not_found');
          }
          if (semester.isEmpty) errors.add('semester_number_required');
          if (offeringId.isNotEmpty) {
            if (!_offeringIds.contains(offeringId)) {
              errors.add('offering_id_not_found');
            } else {
              classification = ImportStudioRowClassification.update;
            }
            dedupeKey = offeringId;
          } else if (termId != null) {
            dedupeKey = '$groupName|$subjectName|$termId';
            if (_offeringIdByKey.containsKey(dedupeKey)) {
              classification = ImportStudioRowClassification.update;
            }
          }
        case 'teacher_links':
          final linkId = '${source['teacher_link_id'] ?? ''}'.trim();
          var offeringId = '${source['offering_id'] ?? ''}'.trim();
          final teacherName = _norm(
            '${source['teacher_full_name'] ?? source['teacher_id'] ?? ''}',
          );
          final role = '${source['role'] ?? ''}'.trim();
          if (offeringId.isNotEmpty) {
            if (!_offeringIds.contains(offeringId)) {
              errors.add('offering_id_not_found');
            }
          } else {
            final groupName = _norm('${source['group_name'] ?? ''}');
            final subjectName = _norm('${source['subject_name'] ?? ''}');
            final yearName = _norm('${source['academic_year_name'] ?? ''}');
            final termName = _norm('${source['term_name'] ?? ''}');
            if (groupName.isEmpty || subjectName.isEmpty) {
              errors.add('group_name_and_subject_name_required');
            }
            final termId = _termIdByKey['$yearName|$termName'];
            if (termId == null) {
              errors.add('term_not_found');
            } else {
              final resolved = _offeringIdByKey['$groupName|$subjectName|$termId'];
              if (resolved == null) {
                errors.add('offering_not_found');
              } else {
                offeringId = resolved;
              }
            }
          }
          if (teacherName.isEmpty) {
            errors.add('teacher_id_or_teacher_full_name_required');
          }
          if (linkId.isNotEmpty) {
            classification = ImportStudioRowClassification.update;
            dedupeKey = linkId;
          } else if (offeringId.isNotEmpty && teacherName.isNotEmpty) {
            dedupeKey = '$offeringId|$teacherName|$role';
            if (_teacherLinkIdByKey.containsKey(dedupeKey)) {
              classification = ImportStudioRowClassification.update;
            }
          }
        case 'enrollments':
          final enrollmentId = '${source['enrollment_id'] ?? ''}'.trim();
          final login = '${source['login'] ?? ''}'.trim().toLowerCase();
          final groupName = _norm('${source['group_name'] ?? ''}');
          if (login.isEmpty) errors.add('login_required');
          if (groupName.isEmpty) {
            errors.add('group_name_required');
          } else if (!_groupIdByName.containsKey(groupName)) {
            errors.add('group_not_found');
          }
          final currentGroup = _activeEnrollmentGroupByLogin[login];
          if (currentGroup != null && currentGroup != groupName) {
            errors.add('user_already_enrolled_in_other_group');
          }
          if (enrollmentId.isNotEmpty) {
            classification = ImportStudioRowClassification.update;
            dedupeKey = enrollmentId;
          } else {
            dedupeKey = '$login|$groupName';
            if (_enrollmentIdByKey.containsKey(dedupeKey)) {
              classification = ImportStudioRowClassification.update;
            }
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

  ImportStudioBatchSummary _summarize(
    String domain,
    List<ImportStudioDiffRow> rows,
  ) {
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
      warnings: _warningsFor(domain, newCount),
    );
  }

  /// Mirrors `private.import_studio_batch_warnings` — side effects the SQL
  /// dry-run predicts and surfaces to the admin before confirm apply.
  List<String> _warningsFor(String domain, int newCount) {
    if (newCount <= 0) return const [];
    switch (domain) {
      case 'groups':
        return [
          'Будет создано $newCount новых групп(ы). Для каждой автоматически создаётся group_space team + chat.',
        ];
      case 'students':
        return [
          'Будет создано $newCount новых аккаунтов студентов (auth-провижининг). Откат недоступен.',
        ];
      case 'offerings':
        return [
          'Будет создано $newCount новых subject_offerings. Предметные команды/чаты создаются отдельно через term backfill, не этим импортом.',
        ];
      case 'enrollments':
        return [
          'Будет создано $newCount новых зачислений. Перевод между группами этим импортом не поддерживается — только новые зачисления.',
        ];
      case 'terms':
        return [
          'Будет создано $newCount новых семестров. Текущий семестр не переключается этим импортом.',
        ];
      default:
        return const [];
    }
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

/// Result of [LocalImportStudioRepository._applyDomainSideEffects]: per-row
/// entity id plus whether THIS apply call created it (vs. matching a
/// pre-existing one) — mirrors the SQL migration's `apply_created` column.
class _ApplyOutcome {
  const _ApplyOutcome(
    this.appliedEntityIds,
    this.createdFlags,
    this.fingerprints,
  );

  final List<String?> appliedEntityIds;
  final List<bool> createdFlags;
  final List<String?> fingerprints;
}

class _LocalBatchRecord {
  const   _LocalBatchRecord({
    required this.batch,
    required this.rows,
    required this.payloadHash,
    this.appliedEntityIds = const [],
    this.applyCreated = const [],
    this.applyRowFingerprint = const [],
  });

  final ImportStudioBatch batch;
  final List<ImportStudioDiffRow> rows;
  final String payloadHash;

  /// Per-row entity id created/matched at apply time (parallel to [rows]).
  /// Only ever populated for the six domains with local world-state
  /// (groups, curriculum, terms, offerings, teacher_links, enrollments);
  /// used by rollback to know exactly which rows to undo.
  final List<String?> appliedEntityIds;

  /// Per-row flag (parallel to [rows] / [appliedEntityIds]): true only if
  /// THIS apply call actually created the entity at [appliedEntityIds]\[i\]
  /// (as opposed to matching/updating a pre-existing one). Recorded
  /// atomically at apply time, independent of the dry-run classification —
  /// rollback deletes by this flag, never by classification alone.
  final List<bool> applyCreated;

  /// Per-row snapshot (parallel to [rows]) captured the instant
  /// [applyCreated]\[i\] was set to true — mirrors `apply_row_fingerprint`.
  /// Null for rows that matched/updated a pre-existing entity.
  final List<String?> applyRowFingerprint;

  _LocalBatchRecord copyWith({
    ImportStudioBatch? batch,
    List<ImportStudioDiffRow>? rows,
    String? payloadHash,
    List<String?>? appliedEntityIds,
    List<bool>? applyCreated,
    List<String?>? applyRowFingerprint,
  }) {
    return _LocalBatchRecord(
      batch: batch ?? this.batch,
      rows: rows ?? this.rows,
      payloadHash: payloadHash ?? this.payloadHash,
      appliedEntityIds: appliedEntityIds ?? this.appliedEntityIds,
      applyCreated: applyCreated ?? this.applyCreated,
      applyRowFingerprint: applyRowFingerprint ?? this.applyRowFingerprint,
    );
  }
}

extension on ImportStudioBatch {
  ImportStudioBatch copyWith({
    ImportStudioBatchStatus? status,
    bool? alreadyApplied,
    bool? idempotentReplay,
    bool? rollbackSafe,
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
      rollbackSafe: rollbackSafe ?? this.rollbackSafe,
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
