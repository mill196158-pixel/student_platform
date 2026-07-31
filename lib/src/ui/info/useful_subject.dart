import 'subject_difficulty.dart';

/// Subject row shown on the Info tab (mapped from `rpc_get_my_subjects_v2`).
class UsefulSubject {
  final String id;
  final String title;
  final String? subjectId;
  final String? groupId;
  final int? semesterNumber;
  final String controlForm;
  final String description;
  final String teacherName;
  final String? teamId;
  final String teamName;
  final String teamIcon;
  final String teamGroupName;
  final String? chatId;
  final double avgDifficultyGlobal;
  final double avgDifficultyLocal;
  final int votesCountGlobal;
  final int votesCountLocal;

  const UsefulSubject({
    required this.id,
    required this.title,
    this.subjectId,
    this.groupId,
    this.semesterNumber,
    required this.controlForm,
    required this.description,
    required this.teacherName,
    this.teamId,
    required this.teamName,
    required this.teamIcon,
    required this.teamGroupName,
    this.chatId,
    this.avgDifficultyGlobal = 0,
    this.avgDifficultyLocal = 0,
    this.votesCountGlobal = 0,
    this.votesCountLocal = 0,
  });

  SubjectDifficultySummary get difficulty => SubjectDifficultySummary(
        avgDifficultyGlobal: avgDifficultyGlobal,
        avgDifficultyLocal: avgDifficultyLocal,
      );

  bool get hasChat => chatId != null && teamId != null;

  factory UsefulSubject.fromRpcMap(Map<String, dynamic> row) {
    final shortDescription = (row['short_description'] ?? '').toString().trim();
    final localDescription = (row['local_description'] ?? '').toString().trim();
    final description =
        shortDescription.isNotEmpty ? shortDescription : localDescription;

    return UsefulSubject(
      id: (row['subject_offering_id'] ?? row['id'] ?? '').toString(),
      title: _firstNonEmpty([
        row['subject_title'],
        row['display_name'],
        'Без названия',
      ]),
      subjectId: _nullIfEmpty(row['subject_id']),
      groupId: _nullIfEmpty(row['group_id']),
      semesterNumber: _asIntOrNull(row['semester_number']),
      controlForm: (row['control_form'] ?? '').toString().trim(),
      description: description,
      teacherName: '',
      teamId: _nullIfEmpty(row['team_id']),
      teamName: '',
      teamIcon: '',
      teamGroupName: '',
      chatId: _nullIfEmpty(row['chat_id']),
      avgDifficultyGlobal: _asDouble(row['avg_difficulty_global']),
      avgDifficultyLocal: _asDouble(row['avg_difficulty_local']),
      votesCountGlobal: _asInt(row['votes_count_global']),
      votesCountLocal: _asInt(row['votes_count_local']),
    );
  }

  /// Bounded nested-select fallback row (no per-subject difficulty).
  factory UsefulSubject.fromFallbackMap(Map<String, dynamic> row) {
    final curriculum = _asMap(row['curriculum_subjects']);
    final catalog = _asMap(row['subject_catalog']);
    final controlForm = (curriculum['control_form'] ?? '').toString().trim();

    return UsefulSubject(
      id: (row['id'] ?? '').toString(),
      title: _firstNonEmpty([
        curriculum['display_name'],
        curriculum['raw_subject_name'],
        row['display_name'],
        catalog['canonical_name'],
        'Без названия',
      ]),
      subjectId: _nullIfEmpty(row['subject_id']),
      groupId: _nullIfEmpty(row['group_id']),
      semesterNumber: _asIntOrNull(row['semester_number']),
      controlForm: controlForm,
      description: (catalog['description'] ?? '').toString().trim(),
      teacherName: '',
      teamId: null,
      teamName: '',
      teamIcon: '',
      teamGroupName: '',
      chatId: null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subjectId': subjectId,
        'groupId': groupId,
        'semesterNumber': semesterNumber,
        'controlForm': controlForm,
        'description': description,
        'teacherName': teacherName,
        'teamId': teamId,
        'teamName': teamName,
        'teamIcon': teamIcon,
        'teamGroupName': teamGroupName,
        'chatId': chatId,
        'avgDifficultyGlobal': avgDifficultyGlobal,
        'avgDifficultyLocal': avgDifficultyLocal,
        'votesCountGlobal': votesCountGlobal,
        'votesCountLocal': votesCountLocal,
      };

  factory UsefulSubject.fromJson(Map<String, dynamic> json) {
    return UsefulSubject(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      subjectId: _nullIfEmpty(json['subjectId']),
      groupId: _nullIfEmpty(json['groupId']),
      semesterNumber: _asIntOrNull(json['semesterNumber']),
      controlForm: (json['controlForm'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      teacherName: (json['teacherName'] ?? '').toString(),
      teamId: _nullIfEmpty(json['teamId']),
      teamName: (json['teamName'] ?? '').toString(),
      teamIcon: (json['teamIcon'] ?? '').toString(),
      teamGroupName: (json['teamGroupName'] ?? '').toString(),
      chatId: _nullIfEmpty(json['chatId']),
      avgDifficultyGlobal: _asDouble(json['avgDifficultyGlobal']),
      avgDifficultyLocal: _asDouble(json['avgDifficultyLocal']),
      votesCountGlobal: _asInt(json['votesCountGlobal']),
      votesCountLocal: _asInt(json['votesCountLocal']),
    );
  }
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return const {};
}

double _asDouble(dynamic value) {
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) {
    return double.tryParse(value.replaceAll(',', '.')) ?? 0;
  }
  return 0;
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int? _asIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

String? _nullIfEmpty(dynamic value) {
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? null : text;
}

String _firstNonEmpty(List<dynamic> values) {
  for (final value in values) {
    final text = (value ?? '').toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}
