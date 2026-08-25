import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'academic_process_calendar_models.dart';

abstract class AcademicProcessCalendarRepository {
  Future<AcademicProcessCalendarReferences> loadReferences();

  Future<String> createDraftVersion({
    required String academicYearId,
    required AcademicProcessAudienceKind audienceKind,
    String? audienceId,
    required String title,
    required String versionLabel,
    String? sourceFileName,
    String? sourceMimeType,
    String? localSha256,
  });

  Future<AcademicProcessDryRunResult> dryRun({
    required String versionId,
    required List<AcademicProcessPeriodDraft> rows,
  });
}

class LocalAcademicProcessCalendarRepository
    implements AcademicProcessCalendarRepository {
  int _version = 0;

  @override
  Future<AcademicProcessCalendarReferences> loadReferences() async {
    return const AcademicProcessCalendarReferences(
      years: [AcademicProcessReference(id: 'year-2026', label: '2026/2027')],
      programs: [
        AcademicProcessReference(
          id: 'program-pgs',
          label: '08.03.01 · ПГС · очная',
        ),
      ],
      plans: [
        AcademicProcessReference(
          id: 'plan-pgs-2025',
          parentId: 'program-pgs',
          label: 'СбПГС · приём 2025 · 8 семестров',
          admissionYear: 2025,
          nominalSemesters: 8,
          status: 'reviewed',
        ),
      ],
      groups: [
        AcademicProcessReference(id: 'group-sbpgs', label: 'СбПГС-2025'),
      ],
    );
  }

  @override
  Future<String> createDraftVersion({
    required String academicYearId,
    required AcademicProcessAudienceKind audienceKind,
    String? audienceId,
    required String title,
    required String versionLabel,
    String? sourceFileName,
    String? sourceMimeType,
    String? localSha256,
  }) async {
    if (academicYearId.isEmpty || title.trim().isEmpty) {
      throw StateError('calendar_metadata_required');
    }
    if (audienceKind != AcademicProcessAudienceKind.global &&
        (audienceId == null || audienceId.isEmpty)) {
      throw StateError('calendar_audience_required');
    }
    return 'local-calendar-version-${++_version}';
  }

  @override
  Future<AcademicProcessDryRunResult> dryRun({
    required String versionId,
    required List<AcademicProcessPeriodDraft> rows,
  }) async {
    final items = <Map<String, dynamic>>[];
    var errors = 0;
    final keys = <String>{};
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final rowErrors = <String>[];
      if (row.periodKey.trim().isEmpty) rowErrors.add('period_key_required');
      if (!keys.add(row.periodKey.trim())) {
        rowErrors.add('duplicate_period_key');
      }
      if (row.startsOn == null || row.endsOn == null) {
        rowErrors.add('period_dates_required');
      } else if (row.endsOn!.isBefore(row.startsOn!)) {
        rowErrors.add('period_end_before_start');
      }
      if (row.type == AcademicProcessPeriodType.other &&
          (row.sourceNote?.trim().isEmpty ?? true)) {
        rowErrors.add('other_period_note_required');
      }
      if (rowErrors.isNotEmpty) errors++;
      items.add({
        'row_number': index + 1,
        'period_key': row.periodKey,
        'derived_semester_number': row.semesterNumber,
        'classification': rowErrors.isEmpty ? 'new' : 'error',
        'errors': rowErrors,
        'warnings': const <String>[],
        'payload': row.toJson(),
      });
    }
    return AcademicProcessDryRunResult(
      ok: rows.isNotEmpty && errors == 0,
      applyEnabled: false,
      publishEnabled: false,
      total: rows.length,
      newCount: rows.length - errors,
      errorCount: errors,
      items: items,
    );
  }
}

abstract class AcademicProcessCalendarRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseAcademicProcessCalendarRpcClient
    implements AcademicProcessCalendarRpcClient {
  SupabaseAcademicProcessCalendarRpcClient(this.client);

  final SupabaseClient client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return client.rpc(function, params: params);
  }
}

class SupabaseAcademicProcessCalendarRepository
    implements AcademicProcessCalendarRepository {
  SupabaseAcademicProcessCalendarRepository({
    SupabaseClient? client,
    AcademicProcessCalendarRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseAcademicProcessCalendarRpcClient(
             client ?? Supabase.instance.client,
           );

  static const parserContract = 'academic-process-calendar-v1';

  final AcademicProcessCalendarRpcClient _rpc;

  dynamic _decode(dynamic value) => value is String ? jsonDecode(value) : value;

  List<Map<String, dynamic>> _list(dynamic value) => [
    for (final item in (_decode(value) as List? ?? const []))
      Map<String, dynamic>.from(item as Map),
  ];

  @override
  Future<AcademicProcessCalendarReferences> loadReferences() async {
    final results = await Future.wait([
      _rpc.rpc('admin_list_terms'),
      _rpc.rpc('admin_list_educational_programs'),
      _rpc.rpc(
        'admin_list_curriculum_plans',
        params: {'p_educational_program_id': null, 'p_admission_year': null},
      ),
      _rpc.rpc('admin_list_groups'),
    ]);
    final yearsById = <String, AcademicProcessReference>{};
    for (final term in _list(results[0])) {
      final id = '${term['academic_year_id'] ?? ''}';
      if (id.isEmpty) continue;
      yearsById[id] = AcademicProcessReference(
        id: id,
        label: '${term['year_name'] ?? id}',
      );
    }
    final programs = [
      for (final item in _list(results[1]))
        AcademicProcessReference(
          id: '${item['id']}',
          label:
              '${item['direction_code']} · ${item['profile_name']} · '
              '${_studyFormLabel('${item['study_form']}')}',
          status: item['status']?.toString(),
        ),
    ];
    final plans = [
      for (final item in _list(results[2]))
        AcademicProcessReference(
          id: '${item['id']}',
          parentId: item['educational_program_id']?.toString(),
          label:
              '${item['plan_code']} · приём ${item['admission_year']} · '
              '${item['nominal_semesters']} сем.',
          admissionYear: int.tryParse('${item['admission_year'] ?? ''}'),
          nominalSemesters: int.tryParse('${item['nominal_semesters'] ?? ''}'),
          status: item['status']?.toString(),
        ),
    ];
    final groups = [
      for (final item in _list(results[3]))
        AcademicProcessReference(
          id: '${item['id']}',
          label: '${item['name'] ?? item['id']}',
        ),
    ];
    final years = yearsById.values.toList()
      ..sort((a, b) => b.label.compareTo(a.label));
    return AcademicProcessCalendarReferences(
      years: years,
      programs: programs,
      plans: plans
          .where((item) => const {'reviewed', 'active'}.contains(item.status))
          .toList(),
      groups: groups,
    );
  }

  @override
  Future<String> createDraftVersion({
    required String academicYearId,
    required AcademicProcessAudienceKind audienceKind,
    String? audienceId,
    required String title,
    required String versionLabel,
    String? sourceFileName,
    String? sourceMimeType,
    String? localSha256,
  }) async {
    final existingResult = await _rpc.rpc(
      'admin_list_academic_process_calendars',
      params: {'p_academic_year_id': academicYearId},
    );
    Map<String, dynamic>? existing;
    for (final item in _list(existingResult)) {
      final target = switch (audienceKind) {
        AcademicProcessAudienceKind.global => null,
        AcademicProcessAudienceKind.program =>
          item['educational_program_id']?.toString(),
        AcademicProcessAudienceKind.plan =>
          item['curriculum_plan_id']?.toString(),
        AcademicProcessAudienceKind.group => item['group_id']?.toString(),
      };
      if (item['audience_kind'] == audienceKind.wire && target == audienceId) {
        existing = item;
        break;
      }
    }

    dynamic calendarId;
    if (existing == null) {
      calendarId = await _rpc.rpc(
        'admin_upsert_academic_process_calendar',
        params: _calendarParams(
          academicYearId: academicYearId,
          audienceKind: audienceKind,
          audienceId: audienceId,
          title: title,
        ),
      );
    } else if ('${existing['title'] ?? ''}'.trim() != title.trim()) {
      calendarId = await _rpc.rpc(
        'admin_upsert_academic_process_calendar',
        params: _calendarParams(
          id: '${existing['id']}',
          expectedRowVersion: int.tryParse('${existing['row_version'] ?? ''}'),
          academicYearId: academicYearId,
          audienceKind: audienceKind,
          audienceId: audienceId,
          title: title,
        ),
      );
    } else {
      calendarId = existing['id'];
    }

    final versionId = await _rpc.rpc(
      'admin_create_academic_process_calendar_version',
      params: {
        'p_calendar_id': '$calendarId',
        'p_version_label': versionLabel.trim(),
        'p_source_file_name': _nullable(sourceFileName),
        'p_source_mime_type': _nullable(sourceMimeType),
        'p_source_sha256': _nullable(localSha256?.toLowerCase()),
        'p_parser_contract_version': parserContract,
      },
    );
    return '$versionId';
  }

  Map<String, dynamic> _calendarParams({
    String? id,
    int? expectedRowVersion,
    required String academicYearId,
    required AcademicProcessAudienceKind audienceKind,
    String? audienceId,
    required String title,
  }) {
    return {
      'p_id': id,
      'p_academic_year_id': academicYearId,
      'p_audience_kind': audienceKind.wire,
      'p_educational_program_id':
          audienceKind == AcademicProcessAudienceKind.program
          ? audienceId
          : null,
      'p_curriculum_plan_id': audienceKind == AcademicProcessAudienceKind.plan
          ? audienceId
          : null,
      'p_group_id': audienceKind == AcademicProcessAudienceKind.group
          ? audienceId
          : null,
      'p_title': title.trim(),
      'p_expected_row_version': expectedRowVersion,
    };
  }

  @override
  Future<AcademicProcessDryRunResult> dryRun({
    required String versionId,
    required List<AcademicProcessPeriodDraft> rows,
  }) async {
    final result = await _rpc.rpc(
      'admin_academic_process_calendar_dry_run',
      params: {
        'p_calendar_version_id': versionId,
        'p_parser_contract_version': parserContract,
        'p_rows': [for (final row in rows) row.toJson()],
      },
    );
    return AcademicProcessDryRunResult.fromJson(
      Map<String, dynamic>.from(_decode(result) as Map),
    );
  }

  static String? _nullable(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String _studyFormLabel(String value) => switch (value) {
    'full_time' => 'очная',
    'part_time' => 'очно-заочная',
    'extramural' => 'заочная',
    _ => value,
  };
}
