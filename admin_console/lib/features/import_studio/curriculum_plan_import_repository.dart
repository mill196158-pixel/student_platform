import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'academic_document_draft.dart';

class CurriculumPlanImportException implements Exception {
  const CurriculumPlanImportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class CurriculumPlanTarget {
  const CurriculumPlanTarget({
    required this.programId,
    required this.planId,
    required this.planCode,
    required this.planRowVersion,
  });

  final String programId;
  final String planId;
  final String planCode;
  final int planRowVersion;
}

class CurriculumSubjectReference {
  const CurriculumSubjectReference({required this.id, required this.name});

  final String id;
  final String name;
}

class CurriculumPlanDryRunResult {
  const CurriculumPlanDryRunResult({
    required this.ok,
    required this.applyEnabled,
    required this.previewId,
    required this.summary,
    required this.items,
    this.applyBlocker,
  });

  final bool ok;
  final bool applyEnabled;
  final String? previewId;
  final String? applyBlocker;
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> items;

  factory CurriculumPlanDryRunResult.fromJson(Map<String, dynamic> json) {
    return CurriculumPlanDryRunResult(
      ok: json['ok'] == true || json['apply_enabled'] == true,
      applyEnabled: json['apply_enabled'] == true,
      previewId: (json['preview_id'] ?? json['preview_token'])?.toString(),
      applyBlocker: json['apply_blocker']?.toString(),
      summary: Map<String, dynamic>.from(json['summary'] as Map? ?? const {}),
      items: [
        for (final item in (json['items'] as List? ?? const []))
          Map<String, dynamic>.from(item as Map),
      ],
    );
  }
}

class CurriculumPlanApplyResult {
  const CurriculumPlanApplyResult({
    required this.ok,
    required this.replayed,
    required this.summary,
  });

  final bool ok;
  final bool replayed;
  final Map<String, dynamic> summary;

  factory CurriculumPlanApplyResult.fromJson(Map<String, dynamic> json) {
    return CurriculumPlanApplyResult(
      ok: json['ok'] == true,
      replayed: json['idempotent_replay'] == true,
      summary: Map<String, dynamic>.from(json['summary'] as Map? ?? const {}),
    );
  }
}

abstract class CurriculumPlanImportRepository {
  Future<List<CurriculumSubjectReference>> listSubjects();

  Future<CurriculumPlanTarget> ensureDraftTarget({
    required CurriculumDraftMetadata metadata,
    required String versionLabel,
    required AcademicDocumentDraft source,
  });

  Future<CurriculumPlanDryRunResult> dryRun({
    required CurriculumPlanTarget target,
    required AcademicDocumentDraft source,
    required List<CurriculumDraftRow> rows,
  });

  Future<CurriculumPlanApplyResult> apply({
    required String previewId,
    required String confirmPlanCode,
  });
}

class LocalCurriculumPlanImportRepository
    implements CurriculumPlanImportRepository {
  int _targetCounter = 0;

  @override
  Future<List<CurriculumSubjectReference>> listSubjects() async => const [];

  @override
  Future<CurriculumPlanTarget> ensureDraftTarget({
    required CurriculumDraftMetadata metadata,
    required String versionLabel,
    required AcademicDocumentDraft source,
  }) async {
    final planCode = _required(metadata.planCode, 'plan_code');
    _required(versionLabel, 'version_label');
    if (metadata.studyForm == null ||
        metadata.admissionYear == null ||
        metadata.nominalSemesters == null) {
      throw const CurriculumPlanImportException(
        'plan_metadata_required',
        'Заполните форму обучения, год поступления и количество семестров.',
      );
    }
    final value = ++_targetCounter;
    return CurriculumPlanTarget(
      programId: 'local-program-$value',
      planId: 'local-plan-$value',
      planCode: planCode,
      planRowVersion: 1,
    );
  }

  @override
  Future<CurriculumPlanDryRunResult> dryRun({
    required CurriculumPlanTarget target,
    required AcademicDocumentDraft source,
    required List<CurriculumDraftRow> rows,
  }) async {
    final payload = flattenCurriculumPlanRows(source: source, rows: rows);
    return CurriculumPlanDryRunResult(
      ok: true,
      applyEnabled: true,
      previewId: 'local-preview-${target.planId}',
      summary: {
        'total': payload.length,
        'new': payload.length,
        'update': 0,
        'error': 0,
      },
      items: [
        for (var index = 0; index < payload.length; index++)
          {
            'row_number': index + 1,
            'classification': 'new',
            'payload': payload[index],
            'errors': const <String>[],
            'warnings': const <String>[],
          },
      ],
    );
  }

  @override
  Future<CurriculumPlanApplyResult> apply({
    required String previewId,
    required String confirmPlanCode,
  }) async {
    if (confirmPlanCode.trim().isEmpty) {
      throw const CurriculumPlanImportException(
        'confirmation_required',
        'Введите код плана для подтверждения.',
      );
    }
    return const CurriculumPlanApplyResult(
      ok: true,
      replayed: false,
      summary: {'inserted': 1, 'updated': 0, 'unchanged': 0},
    );
  }
}

abstract class CurriculumPlanImportRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseCurriculumPlanImportRpcClient
    implements CurriculumPlanImportRpcClient {
  SupabaseCurriculumPlanImportRpcClient(this.client);

  final SupabaseClient client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return client.rpc(function, params: params);
  }
}

class SupabaseCurriculumPlanImportRepository
    implements CurriculumPlanImportRepository {
  SupabaseCurriculumPlanImportRepository({
    SupabaseClient? client,
    CurriculumPlanImportRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseCurriculumPlanImportRpcClient(
             client ?? Supabase.instance.client,
           );

  final CurriculumPlanImportRpcClient _rpc;

  dynamic _decode(dynamic value) => value is String ? jsonDecode(value) : value;

  List<Map<String, dynamic>> _list(dynamic value) => [
    for (final item in (_decode(value) as List? ?? const []))
      Map<String, dynamic>.from(item as Map),
  ];

  Map<String, dynamic> _map(dynamic value) =>
      Map<String, dynamic>.from(_decode(value) as Map);

  @override
  Future<List<CurriculumSubjectReference>> listSubjects() async {
    final rows = _list(
      await _rpc.rpc(
        'admin_list_subjects',
        params: {'p_query': null, 'p_status': null, 'p_sort': 'name_asc'},
      ),
    );
    return [
      for (final row in rows)
        if ('${row['id'] ?? ''}'.isNotEmpty && row['status'] != 'archived')
          CurriculumSubjectReference(
            id: '${row['id']}',
            name: '${row['canonical_name'] ?? row['name'] ?? row['id']}',
          ),
    ];
  }

  @override
  Future<CurriculumPlanTarget> ensureDraftTarget({
    required CurriculumDraftMetadata metadata,
    required String versionLabel,
    required AcademicDocumentDraft source,
  }) async {
    final directionCode = _required(metadata.directionCode, 'direction_code');
    final directionName = _required(metadata.directionName, 'direction_name');
    final profileName = _required(metadata.profileName, 'profile_name');
    final qualification = _required(metadata.qualification, 'qualification');
    final studyForm = metadata.studyForm;
    final admissionYear = metadata.admissionYear;
    final nominalSemesters = metadata.nominalSemesters;
    final planCode = _required(metadata.planCode, 'plan_code');
    final normalizedVersion = _required(versionLabel, 'version_label');
    if (studyForm == null ||
        admissionYear == null ||
        nominalSemesters == null) {
      throw const CurriculumPlanImportException(
        'plan_metadata_required',
        'Заполните форму обучения, год поступления и количество семестров.',
      );
    }

    final programs = _list(await _rpc.rpc('admin_list_educational_programs'));
    final matchingPrograms = programs.where(
      (item) =>
          _norm('${item['direction_code']}') == _norm(directionCode) &&
          _norm('${item['profile_name']}') == _norm(profileName) &&
          _norm('${item['qualification']}') == _norm(qualification) &&
          item['study_form'] == studyForm.wire,
    );
    if (matchingPrograms.length > 1) {
      throw const CurriculumPlanImportException(
        'ambiguous_educational_program',
        'Найдено несколько одинаковых образовательных программ.',
      );
    }

    String programId;
    if (matchingPrograms.isEmpty) {
      final result = await _rpc.rpc(
        'admin_upsert_educational_program',
        params: {
          'p_id': null,
          'p_direction_code': directionCode,
          'p_direction_name': directionName,
          'p_profile_name': profileName,
          'p_qualification': qualification,
          'p_study_form': studyForm.wire,
          'p_status': 'draft',
          'p_expected_row_version': null,
        },
      );
      programId = '$result';
    } else {
      programId = '${matchingPrograms.single['id']}';
    }

    var plans = _list(
      await _rpc.rpc(
        'admin_list_curriculum_plans',
        params: {
          'p_educational_program_id': programId,
          'p_admission_year': admissionYear,
        },
      ),
    );
    final matchingPlans = plans.where(
      (item) =>
          _norm('${item['plan_code']}') == _norm(planCode) &&
          _norm('${item['version_label']}') == _norm(normalizedVersion),
    );
    if (matchingPlans.length > 1) {
      throw const CurriculumPlanImportException(
        'ambiguous_curriculum_plan',
        'Найдено несколько одинаковых версий учебного плана.',
      );
    }
    final existing = matchingPlans.firstOrNull;
    if (existing != null && existing['status'] != 'draft') {
      throw const CurriculumPlanImportException(
        'curriculum_plan_not_draft',
        'Эта версия плана уже проверена. Создайте новую версию.',
      );
    }

    final planId = await _rpc.rpc(
      'admin_upsert_curriculum_plan',
      params: {
        'p_id': existing?['id'],
        'p_educational_program_id': programId,
        'p_admission_year': admissionYear,
        'p_plan_code': planCode,
        'p_version_label': normalizedVersion,
        'p_nominal_semesters': nominalSemesters,
        'p_status': 'draft',
        'p_source_title': 'Официальный учебный план',
        'p_source_file_name': source.fileName,
        'p_source_mime_type': _sourceMime(source.fileName),
        'p_source_sha256': source.localSha256,
        'p_parser_contract_version': source.contractVersion,
        'p_expected_row_version': existing?['row_version'],
      },
    );

    plans = _list(
      await _rpc.rpc(
        'admin_list_curriculum_plans',
        params: {
          'p_educational_program_id': programId,
          'p_admission_year': admissionYear,
        },
      ),
    );
    final refreshed = plans.where((item) => '${item['id']}' == '$planId');
    if (refreshed.length != 1) {
      throw const CurriculumPlanImportException(
        'curriculum_plan_refresh_failed',
        'Не удалось перечитать созданную версию плана.',
      );
    }
    return CurriculumPlanTarget(
      programId: programId,
      planId: '$planId',
      planCode: planCode,
      planRowVersion: int.tryParse('${refreshed.single['row_version']}') ?? 1,
    );
  }

  @override
  Future<CurriculumPlanDryRunResult> dryRun({
    required CurriculumPlanTarget target,
    required AcademicDocumentDraft source,
    required List<CurriculumDraftRow> rows,
  }) async {
    final payload = flattenCurriculumPlanRows(source: source, rows: rows);
    final result = await _rpc.rpc(
      'admin_curriculum_plan_import_dry_run_v2',
      params: {
        'p_curriculum_plan_id': target.planId,
        'p_expected_row_version': target.planRowVersion,
        'p_parser_contract_version': source.contractVersion,
        'p_rows': payload,
        'p_source_reviewed': true,
        'p_file_name': source.fileName,
        'p_source_mime_type': _sourceMime(source.fileName),
        'p_client_source_sha256': source.localSha256,
      },
    );
    return CurriculumPlanDryRunResult.fromJson(_map(result));
  }

  @override
  Future<CurriculumPlanApplyResult> apply({
    required String previewId,
    required String confirmPlanCode,
  }) async {
    final result = await _rpc.rpc(
      'admin_curriculum_plan_import_apply',
      params: {
        'p_preview_id': previewId,
        'p_confirm_plan_code': confirmPlanCode.trim(),
      },
    );
    return CurriculumPlanApplyResult.fromJson(_map(result));
  }
}

List<Map<String, dynamic>> flattenCurriculumPlanRows({
  required AcademicDocumentDraft source,
  required List<CurriculumDraftRow> rows,
}) {
  if (source.isManualRequired ||
      source.blockingIssues.isNotEmpty ||
      rows.any((row) => row.requiresReview)) {
    throw const CurriculumPlanImportException(
      'draft_not_reviewed',
      'Подтвердите все строки и устраните блокирующие замечания.',
    );
  }
  final hashPrefix = source.localSha256.length >= 16
      ? source.localSha256.substring(0, 16)
      : source.localSha256;
  final result = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (row.disposition != CurriculumRowDisposition.occurrence) continue;
    final occurrences = [...row.occurrences]
      ..sort((a, b) => a.semesterNumber.compareTo(b.semesterNumber));
    final sourceSubjectKey = '$hashPrefix:${row.candidateKey}';
    for (var index = 0; index < occurrences.length; index++) {
      final occurrence = occurrences[index];
      final assessments =
          occurrence.assessments
              .map((item) => item.type)
              .where((type) => type != CurriculumAssessmentType.unknown)
              .map((type) => type.wire)
              .toSet()
              .toList()
            ..sort();
      result.add({
        'source_subject_key': sourceSubjectKey,
        'source_occurrence_key':
            '$sourceSubjectKey|s${occurrence.semesterNumber}',
        'subject_index': row.subjectIndex.trim(),
        'subject_name': row.subjectName.trim(),
        'subject_id': row.subjectId,
        'semester_number': occurrence.semesterNumber,
        'is_aggregate_owner': index == 0,
        'hours_total': index == 0 ? row.hoursTotal : null,
        'credits': index == 0 ? row.credits : null,
        'assessment_types': assessments,
        'workload': occurrence.workload,
        'block_name': row.blockName,
        'source_page': occurrence.sourcePage,
        'source_region':
            (occurrence.sourceRegion ?? row.sourceRegion)?.toJson() ?? {},
        'source_parser_version': source.parserVersion,
        'review_attested': true,
        'has_unresolved_markers': false,
      });
    }
  }
  if (result.isEmpty) {
    throw const CurriculumPlanImportException(
      'no_occurrences_to_import',
      'В проверенном плане нет дисциплин для сохранения.',
    );
  }
  return result;
}

String _required(String? value, String field) {
  final normalized = value?.trim() ?? '';
  if (normalized.isEmpty) {
    throw CurriculumPlanImportException(
      '${field}_required',
      'Не заполнено обязательное поле: $field.',
    );
  }
  return normalized;
}

String _norm(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String _sourceMime(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
