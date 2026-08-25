import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

class GroupRecognitionException implements Exception {
  const GroupRecognitionException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class GroupRecognitionAcademicYear {
  const GroupRecognitionAcademicYear({
    required this.id,
    required this.name,
    required this.startYear,
    required this.isCurrent,
  });

  final String id;
  final String name;
  final int startYear;
  final bool isCurrent;

  factory GroupRecognitionAcademicYear.fromJson(Map<String, dynamic> json) {
    return GroupRecognitionAcademicYear(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      startYear: (json['start_year'] as num?)?.toInt() ?? 0,
      isCurrent: json['is_current'] == true,
    );
  }
}

class GroupRecognitionItem {
  const GroupRecognitionItem({
    required this.rowId,
    required this.sourceRowKey,
    required this.rawGroupName,
    required this.classification,
    this.normalizedGroupName,
    this.parallelNumber,
    this.programAliasKey,
    this.courseNumber,
    this.derivedAdmissionYear,
    this.candidateGroupIds = const [],
    this.candidatePlanIds = const [],
    this.candidateGroups = const [],
    this.candidatePlans = const [],
    this.warnings = const [],
    this.decision,
  });

  final String rowId;
  final String sourceRowKey;
  final String rawGroupName;
  final String classification;
  final String? normalizedGroupName;
  final int? parallelNumber;
  final String? programAliasKey;
  final int? courseNumber;
  final int? derivedAdmissionYear;
  final List<String> candidateGroupIds;
  final List<String> candidatePlanIds;
  final List<GroupRecognitionGroupCandidate> candidateGroups;
  final List<GroupRecognitionPlanCandidate> candidatePlans;
  final List<String> warnings;
  final GroupRecognitionDecision? decision;

  bool get isActionable => const {
    'exact_group',
    'exact_alias',
    'semantic_duplicate',
    'new_candidate',
    'ambiguous_plan',
  }.contains(classification);

  bool get isBlocked => !isActionable;

  factory GroupRecognitionItem.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) {
      if (value is! List) return const [];
      return value.map((item) => '$item').toList(growable: false);
    }

    final evidence = json['evidence'];
    final candidateSnapshot = evidence is Map
        ? evidence['candidate_snapshot']
        : null;
    final snapshot = candidateSnapshot is Map
        ? Map<String, dynamic>.from(candidateSnapshot)
        : const <String, dynamic>{};
    final rawGroups = <dynamic>[
      ...?snapshot['alias_groups'] as List?,
      ...?snapshot['semantic_groups'] as List?,
    ];
    final groupsById = <String, GroupRecognitionGroupCandidate>{};
    for (final value in rawGroups.whereType<Map>()) {
      final candidate = GroupRecognitionGroupCandidate.fromJson(
        Map<String, dynamic>.from(value),
      );
      if (candidate.id.isNotEmpty) groupsById[candidate.id] = candidate;
    }
    final rawPlans = snapshot['plans'];
    final rawDecision = json['decision'];
    return GroupRecognitionItem(
      rowId: '${json['row_id'] ?? ''}',
      sourceRowKey: '${json['source_row_key'] ?? ''}',
      rawGroupName: '${json['raw_group_name'] ?? ''}',
      classification: '${json['classification'] ?? 'conflict'}',
      normalizedGroupName: json['normalized_group_name']?.toString(),
      parallelNumber: (json['parallel_number'] as num?)?.toInt(),
      programAliasKey: json['program_alias_key']?.toString(),
      courseNumber: (json['course_number'] as num?)?.toInt(),
      derivedAdmissionYear: (json['derived_admission_year'] as num?)?.toInt(),
      candidateGroupIds: strings(json['candidate_group_ids']),
      candidatePlanIds: strings(json['candidate_plan_ids']),
      candidateGroups: groupsById.values.toList(growable: false),
      candidatePlans: rawPlans is List
          ? rawPlans
                .whereType<Map>()
                .map(
                  (value) => GroupRecognitionPlanCandidate.fromJson(
                    Map<String, dynamic>.from(value),
                  ),
                )
                .toList(growable: false)
          : const [],
      warnings: strings(json['warnings']),
      decision: rawDecision is Map
          ? GroupRecognitionDecision.fromJson(
              Map<String, dynamic>.from(rawDecision),
            )
          : null,
    );
  }
}

class GroupRecognitionGroupCandidate {
  const GroupRecognitionGroupCandidate({
    required this.id,
    required this.name,
    required this.label,
    this.identity,
    this.profile,
    this.maxTermSemester = 0,
  });

  final String id;
  final String name;
  final String label;
  final Map<String, dynamic>? identity;
  final Map<String, dynamic>? profile;
  final int maxTermSemester;

  factory GroupRecognitionGroupCandidate.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? map(dynamic value) =>
        value is Map ? Map<String, dynamic>.from(value) : null;
    final id = '${json['group_id'] ?? ''}';
    final name = '${json['group_name'] ?? 'Группа без названия'}';
    return GroupRecognitionGroupCandidate(
      id: id,
      name: name,
      label: '${json['label'] ?? name}',
      identity: map(json['identity']),
      profile: map(json['profile']),
      maxTermSemester: (json['max_term_semester'] as num?)?.toInt() ?? 0,
    );
  }
}

class GroupRecognitionPlanCandidate {
  const GroupRecognitionPlanCandidate({
    required this.id,
    required this.label,
    required this.status,
    required this.nominalSemesters,
  });

  final String id;
  final String label;
  final String status;
  final int nominalSemesters;

  factory GroupRecognitionPlanCandidate.fromJson(Map<String, dynamic> json) {
    return GroupRecognitionPlanCandidate(
      id: '${json['plan_id'] ?? ''}',
      label: '${json['label'] ?? json['plan_code'] ?? 'Учебный план'}',
      status: '${json['status'] ?? ''}',
      nominalSemesters: (json['nominal_semesters'] as num?)?.toInt() ?? 0,
    );
  }
}

enum GroupRecognitionDecisionAction {
  reuseGroup('reuse_group'),
  addAlias('add_alias'),
  createGroup('create_group');

  const GroupRecognitionDecisionAction(this.wire);
  final String wire;

  static GroupRecognitionDecisionAction? parse(String? value) {
    for (final action in values) {
      if (action.wire == value) return action;
    }
    return null;
  }
}

class GroupRecognitionDecision {
  const GroupRecognitionDecision({
    required this.previewRowId,
    required this.action,
    this.id,
    this.selectedGroupId,
    this.selectedPlanId,
    this.distinctDiscriminator = '',
    this.distinctReason,
  });

  final String? id;
  final String previewRowId;
  final GroupRecognitionDecisionAction action;
  final String? selectedGroupId;
  final String? selectedPlanId;
  final String distinctDiscriminator;
  final String? distinctReason;

  Map<String, dynamic> toJson() => {
    'preview_row_id': previewRowId,
    'action': action.wire,
    'selected_group_id': selectedGroupId,
    'selected_plan_id': selectedPlanId,
    'distinct_discriminator': distinctDiscriminator,
    'distinct_reason': distinctReason,
  };

  factory GroupRecognitionDecision.fromJson(Map<String, dynamic> json) {
    return GroupRecognitionDecision(
      id: json['id']?.toString(),
      previewRowId: '${json['preview_row_id'] ?? ''}',
      action:
          GroupRecognitionDecisionAction.parse(json['action']?.toString()) ??
          GroupRecognitionDecisionAction.reuseGroup,
      selectedGroupId: json['selected_group_id']?.toString(),
      selectedPlanId: json['selected_plan_id']?.toString(),
      distinctDiscriminator: '${json['distinct_discriminator'] ?? ''}',
      distinctReason: json['distinct_reason']?.toString(),
    );
  }
}

class GroupRecognitionApplyResult {
  const GroupRecognitionApplyResult({
    required this.action,
    required this.groupName,
    required this.aliasOutcome,
    required this.identityOutcome,
    required this.profileOutcome,
    required this.planLabel,
  });

  final String action;
  final String groupName;
  final String aliasOutcome;
  final String identityOutcome;
  final String profileOutcome;
  final String planLabel;

  factory GroupRecognitionApplyResult.fromJson(Map<String, dynamic> json) {
    return GroupRecognitionApplyResult(
      action: '${json['action'] ?? ''}',
      groupName: '${json['group_name'] ?? ''}',
      aliasOutcome: '${json['alias_outcome'] ?? ''}',
      identityOutcome: '${json['identity_outcome'] ?? ''}',
      profileOutcome: '${json['profile_outcome'] ?? ''}',
      planLabel: '${json['plan_label'] ?? ''}',
    );
  }
}

class GroupRecognitionPreview {
  const GroupRecognitionPreview({
    required this.previewId,
    required this.items,
    required this.summary,
    required this.applyEnabled,
    required this.payloadHash,
    required this.rowVersion,
    required this.decisionRevision,
    required this.decisionHash,
    required this.confirmationToken,
    this.results = const [],
    this.idempotentReplay = false,
  });

  final String previewId;
  final List<GroupRecognitionItem> items;
  final Map<String, dynamic> summary;
  final bool applyEnabled;
  final String payloadHash;
  final int rowVersion;
  final int decisionRevision;
  final String decisionHash;
  final String confirmationToken;
  final List<GroupRecognitionApplyResult> results;
  final bool idempotentReplay;

  factory GroupRecognitionPreview.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawSummary = json['summary'];
    return GroupRecognitionPreview(
      previewId: '${json['preview_id'] ?? ''}',
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => GroupRecognitionItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      summary: rawSummary is Map
          ? Map<String, dynamic>.from(rawSummary)
          : const {},
      applyEnabled: json['apply_enabled'] == true,
      payloadHash: '${json['payload_hash'] ?? ''}',
      rowVersion: (json['row_version'] as num?)?.toInt() ?? 0,
      decisionRevision: (json['decision_revision'] as num?)?.toInt() ?? 0,
      decisionHash: '${json['decision_hash'] ?? ''}',
      confirmationToken: '${json['confirmation_token'] ?? ''}',
      results: json['results'] is List
          ? (json['results'] as List)
                .whereType<Map>()
                .map(
                  (value) => GroupRecognitionApplyResult.fromJson(
                    Map<String, dynamic>.from(value),
                  ),
                )
                .toList(growable: false)
          : const [],
      idempotentReplay: json['idempotent_replay'] == true,
    );
  }
}

abstract class GroupRecognitionRepository {
  Future<List<GroupRecognitionAcademicYear>> listAcademicYears();

  Future<GroupRecognitionPreview> startPreview({
    required String academicYearId,
    required List<Map<String, dynamic>> rows,
    required String fileName,
    String? idempotencyKey,
  });

  Future<GroupRecognitionPreview> saveDecisions({
    required GroupRecognitionPreview preview,
    required List<GroupRecognitionDecision> decisions,
  });

  Future<GroupRecognitionPreview> apply({
    required GroupRecognitionPreview preview,
  });
}

abstract class GroupRecognitionRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseGroupRecognitionRpcClient implements GroupRecognitionRpcClient {
  SupabaseGroupRecognitionRpcClient(this.client);

  final SupabaseClient client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return client.rpc(function, params: params);
  }
}

class SupabaseGroupRecognitionRepository implements GroupRecognitionRepository {
  SupabaseGroupRecognitionRepository({
    SupabaseClient? client,
    GroupRecognitionRpcClient? rpcClient,
  }) : _rpc =
           rpcClient ??
           SupabaseGroupRecognitionRpcClient(
             client ?? Supabase.instance.client,
           );

  final GroupRecognitionRpcClient _rpc;

  dynamic _decode(dynamic value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {}
    }
    return value;
  }

  Map<String, dynamic> _map(dynamic value) {
    final decoded = _decode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const GroupRecognitionException('Некорректный ответ сервера.');
  }

  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc.rpc(function, params: params);
    } on PostgrestException catch (error) {
      final message = error.message.toLowerCase();
      if (error.code == '42501' || message.contains('forbidden')) {
        throw const GroupRecognitionException(
          'Недостаточно прав для проверки групп.',
          code: 'forbidden',
        );
      }
      if (message.contains('could not find the function') ||
          error.code == 'PGRST202') {
        throw const GroupRecognitionException(
          'Проверка групп ещё не применена к Supabase.',
          code: 'rpc_missing',
        );
      }
      if (error.code == '40001' ||
          message.contains('stale') ||
          message.contains('conflict')) {
        throw const GroupRecognitionException(
          'Данные изменились после проверки. Обновите предпросмотр.',
          code: 'stale',
        );
      }
      if (message.contains('duplicate_decision_ids')) {
        throw const GroupRecognitionException(
          'Одна строка получила несколько решений.',
          code: 'duplicate_decision_ids',
        );
      }
      if (message.contains('incomplete_or_blocked')) {
        throw const GroupRecognitionException(
          'Сначала устраните ошибки и сохраните решение для каждой строки.',
          code: 'incomplete_or_blocked',
        );
      }
      throw GroupRecognitionException(
        'Не удалось проверить группы: ${error.message}',
        code: error.code,
      );
    }
  }

  @override
  Future<List<GroupRecognitionAcademicYear>> listAcademicYears() async {
    final decoded = _decode(
      await _call('admin_group_recognition_list_academic_years'),
    );
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map(
          (item) => GroupRecognitionAcademicYear.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<GroupRecognitionPreview> startPreview({
    required String academicYearId,
    required List<Map<String, dynamic>> rows,
    required String fileName,
    String? idempotencyKey,
  }) async {
    final response = await _call('admin_group_recognition_start_preview', {
      'p_academic_year_id': academicYearId,
      'p_rows': rows,
      'p_file_name': fileName,
      'p_idempotency_key': idempotencyKey,
      'p_source_sha256': null,
    });
    return GroupRecognitionPreview.fromJson(_map(response));
  }

  @override
  Future<GroupRecognitionPreview> saveDecisions({
    required GroupRecognitionPreview preview,
    required List<GroupRecognitionDecision> decisions,
  }) async {
    final response = await _call('admin_group_recognition_save_decisions', {
      'p_preview_id': preview.previewId,
      'p_expected_preview_row_version': preview.rowVersion,
      'p_expected_payload_hash': preview.payloadHash,
      'p_decisions': decisions.map((value) => value.toJson()).toList(),
    });
    return GroupRecognitionPreview.fromJson(_map(response));
  }

  @override
  Future<GroupRecognitionPreview> apply({
    required GroupRecognitionPreview preview,
  }) async {
    final response = await _call('admin_group_recognition_apply', {
      'p_preview_id': preview.previewId,
      'p_expected_preview_row_version': preview.rowVersion,
      'p_expected_payload_hash': preview.payloadHash,
      'p_expected_decision_revision': preview.decisionRevision,
      'p_expected_decision_hash': preview.decisionHash,
      'p_confirmation': preview.confirmationToken,
    });
    return GroupRecognitionPreview.fromJson(_map(response));
  }
}

class LocalGroupRecognitionRepository implements GroupRecognitionRepository {
  const LocalGroupRecognitionRepository({this.startYear = 2026});

  final int startYear;

  @override
  Future<List<GroupRecognitionAcademicYear>> listAcademicYears() async {
    return [
      GroupRecognitionAcademicYear(
        id: 'local-$startYear',
        name: '$startYear/${startYear + 1}',
        startYear: startYear,
        isCurrent: true,
      ),
    ];
  }

  @override
  Future<GroupRecognitionPreview> startPreview({
    required String academicYearId,
    required List<Map<String, dynamic>> rows,
    required String fileName,
    String? idempotencyKey,
  }) async {
    final items = <GroupRecognitionItem>[];
    final pattern = RegExp(r'^([1-9][0-9]*)-([^-]+)-([1-9][0-9]*)$');
    final approvedProgramToken = RegExp(
      r'^[a-zа-я0-9]+(?:\([a-zа-я0-9]+\))?$',
      unicode: true,
    );
    for (var index = 0; index < rows.length; index++) {
      final raw = '${rows[index]['group_name'] ?? rows[index]['name'] ?? ''}'
          .trim();
      final validationKey = raw
          .toLowerCase()
          .replaceAll('ё', 'е')
          .replaceAll(RegExp(r'[‐‑‒–—−]'), '-')
          .replaceAll(RegExp(r'\s'), '');
      final normalized = validationKey.replaceAll(RegExp(r'[()]'), '');
      final validationMatch = pattern.firstMatch(validationKey);
      if (validationMatch == null ||
          !approvedProgramToken.hasMatch(validationMatch.group(2)!)) {
        items.add(
          GroupRecognitionItem(
            rowId: 'local-${index + 1}',
            sourceRowKey: '${index + 1}',
            rawGroupName: raw,
            normalizedGroupName: normalized,
            classification: 'parser_blocked',
            warnings: const ['group_name_shape_unrecognized'],
          ),
        );
        continue;
      }
      final match = pattern.firstMatch(normalized)!;
      final course = int.parse(match.group(3)!);
      items.add(
        GroupRecognitionItem(
          rowId: 'local-${index + 1}',
          sourceRowKey: '${index + 1}',
          rawGroupName: raw,
          normalizedGroupName: normalized,
          parallelNumber: int.parse(match.group(1)!),
          programAliasKey: match.group(2)!,
          courseNumber: course,
          derivedAdmissionYear: startYear - course + 1,
          classification: 'program_unregistered',
          warnings: const ['local_preview_requires_reviewed_program_alias'],
        ),
      );
    }
    return GroupRecognitionPreview(
      previewId: 'local-preview',
      items: items,
      summary: {
        'total': items.length,
        'exact': 0,
        'new_candidate': 0,
        'blocked': items.length,
      },
      applyEnabled: false,
      payloadHash: 'local-preview-disabled',
      rowVersion: 1,
      decisionRevision: 0,
      decisionHash: '',
      confirmationToken: '',
    );
  }

  @override
  Future<GroupRecognitionPreview> saveDecisions({
    required GroupRecognitionPreview preview,
    required List<GroupRecognitionDecision> decisions,
  }) {
    throw const GroupRecognitionException(
      'В локальном демо сохранение решений отключено.',
      code: 'local_apply_disabled',
    );
  }

  @override
  Future<GroupRecognitionPreview> apply({
    required GroupRecognitionPreview preview,
  }) {
    throw const GroupRecognitionException(
      'В локальном демо применение отключено.',
      code: 'local_apply_disabled',
    );
  }
}
