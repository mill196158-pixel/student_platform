/// Import Studio domain and batch models aligned with Stage 19 SQL foundation.
///
/// Wire values match `import_studio_batches.domain` and
/// `private.import_studio_domain_state()` in
/// `20260729153000_stage19_import_studio_foundation.sql`.

enum ImportStudioDomainState {
  apply,
  validateOnly,
  notImplemented;

  static ImportStudioDomainState? tryParse(String? raw) {
    switch (raw) {
      case 'apply':
        return ImportStudioDomainState.apply;
      case 'validate_only':
        return ImportStudioDomainState.validateOnly;
      case 'not_implemented':
        return ImportStudioDomainState.notImplemented;
      default:
        return null;
    }
  }

  String get wire {
    switch (this) {
      case ImportStudioDomainState.apply:
        return 'apply';
      case ImportStudioDomainState.validateOnly:
        return 'validate_only';
      case ImportStudioDomainState.notImplemented:
        return 'not_implemented';
    }
  }
}

enum ImportStudioBatchStatus {
  dryRun,
  applied,
  cancelled,
  failed;

  static ImportStudioBatchStatus? tryParse(String? raw) {
    switch (raw) {
      case 'dry_run':
        return ImportStudioBatchStatus.dryRun;
      case 'applied':
        return ImportStudioBatchStatus.applied;
      case 'cancelled':
        return ImportStudioBatchStatus.cancelled;
      case 'failed':
        return ImportStudioBatchStatus.failed;
      default:
        return null;
    }
  }

  String get wire {
    switch (this) {
      case ImportStudioBatchStatus.dryRun:
        return 'dry_run';
      case ImportStudioBatchStatus.applied:
        return 'applied';
      case ImportStudioBatchStatus.cancelled:
        return 'cancelled';
      case ImportStudioBatchStatus.failed:
        return 'failed';
    }
  }
}

enum ImportStudioRowClassification {
  newRow,
  update,
  duplicate,
  error,
  skip;

  static ImportStudioRowClassification? tryParse(String? raw) {
    switch (raw) {
      case 'new':
        return ImportStudioRowClassification.newRow;
      case 'update':
        return ImportStudioRowClassification.update;
      case 'duplicate':
        return ImportStudioRowClassification.duplicate;
      case 'error':
        return ImportStudioRowClassification.error;
      case 'skip':
        return ImportStudioRowClassification.skip;
      default:
        return null;
    }
  }

  String get wire {
    switch (this) {
      case ImportStudioRowClassification.newRow:
        return 'new';
      case ImportStudioRowClassification.update:
        return 'update';
      case ImportStudioRowClassification.duplicate:
        return 'duplicate';
      case ImportStudioRowClassification.error:
        return 'error';
      case ImportStudioRowClassification.skip:
        return 'skip';
    }
  }
}

class ImportStudioDomainInfo {
  const ImportStudioDomainInfo({
    required this.domain,
    required this.label,
    required this.domainState,
    required this.applyPermission,
    required this.supportsApply,
    required this.templateColumns,
    required this.canDryRun,
    required this.canApply,
    this.notes = '',
  });

  final String domain;
  final String label;
  final ImportStudioDomainState domainState;
  final String applyPermission;
  final bool supportsApply;
  final List<String> templateColumns;
  final bool canDryRun;
  final bool canApply;
  final String notes;

  factory ImportStudioDomainInfo.fromJson(Map<String, dynamic> json) {
    final domain = (json['domain'] ?? '').toString();
    return ImportStudioDomainInfo(
      domain: domain,
      label: importStudioDomainLabel(domain),
      domainState:
          ImportStudioDomainState.tryParse(json['domain_state']?.toString()) ??
          ImportStudioDomainState.notImplemented,
      applyPermission: (json['apply_permission'] ?? '').toString(),
      supportsApply: json['supports_apply'] == true,
      templateColumns: _stringList(json['template_columns']),
      canDryRun: json['can_dry_run'] == true,
      canApply: json['can_apply'] == true,
      notes: (json['notes'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'domain': domain,
    'domain_state': domainState.wire,
    'apply_permission': applyPermission,
    'supports_apply': supportsApply,
    'template_columns': templateColumns,
    'can_dry_run': canDryRun,
    'can_apply': canApply,
    'notes': notes,
  };
}

class ImportStudioBatchSummary {
  const ImportStudioBatchSummary({
    this.total = 0,
    this.newCount = 0,
    this.updateCount = 0,
    this.duplicateCount = 0,
    this.errorCount = 0,
  });

  final int total;
  final int newCount;
  final int updateCount;
  final int duplicateCount;
  final int errorCount;

  bool get hasErrors => errorCount > 0;

  factory ImportStudioBatchSummary.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ImportStudioBatchSummary();
    return ImportStudioBatchSummary(
      total: int.tryParse('${json['total'] ?? 0}') ?? 0,
      newCount: int.tryParse('${json['new'] ?? 0}') ?? 0,
      updateCount: int.tryParse('${json['update'] ?? 0}') ?? 0,
      duplicateCount: int.tryParse('${json['duplicate'] ?? 0}') ?? 0,
      errorCount: int.tryParse('${json['error'] ?? 0}') ?? 0,
    );
  }
}

class ImportStudioBatch {
  const ImportStudioBatch({
    required this.batchId,
    required this.domain,
    required this.status,
    required this.batchKey,
    required this.fileName,
    required this.rowCount,
    required this.errorCount,
    required this.summary,
    required this.domainState,
    required this.supportsApply,
    this.alreadyApplied = false,
    this.idempotentReplay = false,
    this.rollbackSafe = false,
  });

  final String batchId;
  final String domain;
  final ImportStudioBatchStatus status;
  final String batchKey;
  final String fileName;
  final int rowCount;
  final int errorCount;
  final ImportStudioBatchSummary summary;
  final ImportStudioDomainState domainState;
  final bool supportsApply;
  final bool alreadyApplied;
  final bool idempotentReplay;
  final bool rollbackSafe;

  bool get canConfirmApply =>
      supportsApply &&
      status == ImportStudioBatchStatus.dryRun &&
      errorCount == 0 &&
      rowCount > 0;

  factory ImportStudioBatch.fromJson(Map<String, dynamic> json) {
    return ImportStudioBatch(
      batchId: (json['batch_id'] ?? json['id'] ?? '').toString(),
      domain: (json['domain'] ?? '').toString(),
      status:
          ImportStudioBatchStatus.tryParse(json['status']?.toString()) ??
          ImportStudioBatchStatus.dryRun,
      batchKey: (json['batch_key'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      rowCount: int.tryParse('${json['row_count'] ?? 0}') ?? 0,
      errorCount: int.tryParse('${json['error_count'] ?? 0}') ?? 0,
      summary: ImportStudioBatchSummary.fromJson(
        json['summary'] is Map
            ? Map<String, dynamic>.from(json['summary'] as Map)
            : null,
      ),
      domainState:
          ImportStudioDomainState.tryParse(json['domain_state']?.toString()) ??
          ImportStudioDomainState.notImplemented,
      supportsApply: json['supports_apply'] == true,
      alreadyApplied: json['already_applied'] == true,
      idempotentReplay: json['idempotent_replay'] == true,
      rollbackSafe: json['rollback_safe'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'batch_id': batchId,
    'domain': domain,
    'status': status.wire,
    'batch_key': batchKey,
    'file_name': fileName,
    'row_count': rowCount,
    'error_count': errorCount,
    'summary': {
      'total': summary.total,
      'new': summary.newCount,
      'update': summary.updateCount,
      'duplicate': summary.duplicateCount,
      'error': summary.errorCount,
    },
    'domain_state': domainState.wire,
    'supports_apply': supportsApply,
    'already_applied': alreadyApplied,
    'idempotent_replay': idempotentReplay,
    'rollback_safe': rollbackSafe,
  };
}

class ImportStudioDiffRow {
  const ImportStudioDiffRow({
    required this.rowNumber,
    required this.classification,
    required this.sourcePayload,
    required this.mappedPayload,
    this.errorText,
  });

  final int rowNumber;
  final ImportStudioRowClassification classification;
  final Map<String, dynamic> sourcePayload;
  final Map<String, dynamic> mappedPayload;
  final String? errorText;

  factory ImportStudioDiffRow.fromJson(Map<String, dynamic> json) {
    return ImportStudioDiffRow(
      rowNumber: int.tryParse('${json['row_number'] ?? 0}') ?? 0,
      classification:
          ImportStudioRowClassification.tryParse(
            json['classification']?.toString(),
          ) ??
          ImportStudioRowClassification.error,
      sourcePayload: json['source_payload'] is Map
          ? Map<String, dynamic>.from(json['source_payload'] as Map)
          : const {},
      mappedPayload: json['mapped_payload'] is Map
          ? Map<String, dynamic>.from(json['mapped_payload'] as Map)
          : const {},
      errorText: json['error_text']?.toString(),
    );
  }
}

class ImportStudioDiff {
  const ImportStudioDiff({
    required this.batch,
    required this.rows,
  });

  final ImportStudioBatch batch;
  final List<ImportStudioDiffRow> rows;
}

class ImportStudioRollbackResult {
  const ImportStudioRollbackResult({
    required this.ok,
    required this.refused,
    required this.batchId,
    required this.domain,
    required this.rollbackSafe,
    required this.errorCode,
    required this.message,
  });

  final bool ok;
  final bool refused;
  final String batchId;
  final String domain;
  final bool rollbackSafe;
  final String errorCode;
  final String message;

  factory ImportStudioRollbackResult.fromJson(Map<String, dynamic> json) {
    return ImportStudioRollbackResult(
      ok: json['ok'] == true,
      refused: json['refused'] == true,
      batchId: (json['batch_id'] ?? '').toString(),
      domain: (json['domain'] ?? '').toString(),
      rollbackSafe: json['rollback_safe'] == true,
      errorCode: (json['error_code'] ?? '').toString(),
      message: (json['message'] ?? '').toString(),
    );
  }
}

/// UI workflow steps for the Import Studio hub (local scaffold).
enum ImportStudioWorkflowStep {
  hub,
  template,
  dryRun,
  diff,
  confirm,
  applied,
}

String importStudioDomainLabel(String domain) {
  switch (domain) {
    case 'teachers':
      return 'Преподаватели';
    case 'subjects':
      return 'Предметы';
    case 'students':
      return 'Студенты';
    case 'groups':
      return 'Группы';
    case 'curriculum':
      return 'Учебные планы';
    case 'terms':
      return 'Семестры';
    case 'offerings':
      return 'Нагрузка (offerings)';
    case 'teacher_links':
      return 'Связи преподавателей';
    case 'enrollments':
      return 'Зачисления';
    default:
      return domain;
  }
}

String importStudioDomainStateLabel(ImportStudioDomainState state) {
  switch (state) {
    case ImportStudioDomainState.apply:
      return 'Apply доступен';
    case ImportStudioDomainState.validateOnly:
      return 'Только dry-run';
    case ImportStudioDomainState.notImplemented:
      return 'Не реализовано';
  }
}

List<String> _stringList(dynamic value) {
  if (value is List) {
    return value.map((e) => e.toString()).toList();
  }
  return const [];
}

/// Template columns from `private.import_studio_template()` (Stage 19 migration).
const importStudioTemplateColumns = <String, List<String>>{
  'teachers': [
    'teacher_id',
    'full_name',
    'email',
    'public_email',
    'department',
    'position',
    'academic_degree',
    'about_text',
    'website',
    'office',
    'telegram',
  ],
  'subjects': [
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
    'useful_links',
    'common_pitfalls',
  ],
  'students': ['login', 'name', 'surname', 'group_name'],
  'groups': ['name'],
  'curriculum': [
    'group_name',
    'subject_name',
    'semester_number',
    'credits',
    'hours_total',
    'control_form',
    'block_name',
    'subject_index',
  ],
  'terms': [
    'academic_year_name',
    'name',
    'term_in_year',
    'starts_on',
    'ends_on',
  ],
};

const importStudioDomainPermissions = <String, String>{
  'teachers': 'teachers.write',
  'subjects': 'subjects.write',
  'students': 'students.write',
  'groups': 'groups.write',
  'curriculum': 'subjects.write',
  'terms': 'terms.manage',
  'offerings': 'subjects.write',
  'teacher_links': 'teachers.write',
  'enrollments': 'students.write',
};

ImportStudioDomainState importStudioDomainStateFor(String domain) {
  switch (domain) {
    case 'teachers':
    case 'subjects':
    case 'students':
      return ImportStudioDomainState.apply;
    case 'groups':
    case 'curriculum':
    case 'terms':
      return ImportStudioDomainState.validateOnly;
    case 'offerings':
    case 'teacher_links':
    case 'enrollments':
      return ImportStudioDomainState.notImplemented;
    default:
      return ImportStudioDomainState.notImplemented;
  }
}

String importStudioDomainNotes(String domain) {
  switch (domain) {
    case 'offerings':
    case 'teacher_links':
    case 'enrollments':
      return 'NOT IMPLEMENTED в Stage 19 foundation. Словарь зафиксирован; вызовы вернут not_implemented_domain_*.';
    case 'terms':
      return 'Validate-only. Импорт не переключает текущий семестр и не создаёт Осень 2026.';
    case 'groups':
    case 'curriculum':
      return 'Validate-only в Stage 19: reviewed apply path ещё нет.';
    default:
      return 'Apply делегируется существующему domain import RPC.';
  }
}
