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
    this.warnings = const [],
  });

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
  final List<String> warnings;

  bool get isBlocked => !const {
    'exact_group',
    'exact_alias',
    'new_candidate',
  }.contains(classification);

  factory GroupRecognitionItem.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) {
      if (value is! List) return const [];
      return value.map((item) => '$item').toList(growable: false);
    }

    return GroupRecognitionItem(
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
      warnings: strings(json['warnings']),
    );
  }
}

class GroupRecognitionPreview {
  const GroupRecognitionPreview({
    required this.previewId,
    required this.items,
    required this.summary,
    required this.applyEnabled,
    required this.applyBlocker,
    this.idempotentReplay = false,
  });

  final String previewId;
  final List<GroupRecognitionItem> items;
  final Map<String, dynamic> summary;
  final bool applyEnabled;
  final String applyBlocker;
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
      applyBlocker: '${json['apply_blocker'] ?? ''}',
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
      applyBlocker: 'group_recognition_foundation_preview_only',
    );
  }
}
