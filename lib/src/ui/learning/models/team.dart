import 'dart:convert';

class Team {
  final String id;
  final String name; // Название команды/предмета
  final String teacher; // Преподаватель
  final String groupCode; // Группа/курс привязки
  final String icon; // Эмодзи/краткая метка в аватаре
  final int unread; // Непрочитанные (демо)
  final bool pollApproved; // Разрешены "Задания" после голосования
  final String? subjectOfferingId;
  final String? groupId;
  final String? subjectId;
  final String? academicYearId;
  final String? academicTermId;
  final int? semesterNumber;

  const Team({
    required this.id,
    required this.name,
    required this.teacher,
    required this.groupCode,
    required this.icon,
    this.unread = 0,
    this.pollApproved = false,
    this.subjectOfferingId,
    this.groupId,
    this.subjectId,
    this.academicYearId,
    this.academicTermId,
    this.semesterNumber,
  });

  Team copyWith({
    String? id,
    String? name,
    String? teacher,
    String? groupCode,
    String? icon,
    int? unread,
    bool? pollApproved,
    String? subjectOfferingId,
    String? groupId,
    String? subjectId,
    String? academicYearId,
    String? academicTermId,
    int? semesterNumber,
  }) {
    return Team(
      id: id ?? this.id,
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      groupCode: groupCode ?? this.groupCode,
      icon: icon ?? this.icon,
      unread: unread ?? this.unread,
      pollApproved: pollApproved ?? this.pollApproved,
      subjectOfferingId: subjectOfferingId ?? this.subjectOfferingId,
      groupId: groupId ?? this.groupId,
      subjectId: subjectId ?? this.subjectId,
      academicYearId: academicYearId ?? this.academicYearId,
      academicTermId: academicTermId ?? this.academicTermId,
      semesterNumber: semesterNumber ?? this.semesterNumber,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'teacher': teacher,
        'groupCode': groupCode,
        'icon': icon,
        'unread': unread,
        'pollApproved': pollApproved,
        'subjectOfferingId': subjectOfferingId,
        'groupId': groupId,
        'subjectId': subjectId,
        'academicYearId': academicYearId,
        'academicTermId': academicTermId,
        'semesterNumber': semesterNumber,
      };

  factory Team.fromJson(Map<String, dynamic> j) => Team(
        id: j['id'] as String,
        name: j['name'] as String,
        teacher: j['teacher'] as String,
        groupCode: j['groupCode'] as String,
        icon: j['icon'] as String,
        unread: (j['unread'] ?? 0) as int,
        pollApproved: (j['pollApproved'] ?? false) as bool,
        subjectOfferingId:
            _nullableString(j['subjectOfferingId'] ?? j['subject_offering_id']),
        groupId: _nullableString(j['groupId'] ?? j['group_id']),
        subjectId: _nullableString(j['subjectId'] ?? j['subject_id']),
        academicYearId:
            _nullableString(j['academicYearId'] ?? j['academic_year_id']),
        academicTermId:
            _nullableString(j['academicTermId'] ?? j['academic_term_id']),
        semesterNumber:
            _nullableInt(j['semesterNumber'] ?? j['semester_number']),
      );

  static String encodeList(List<Team> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  static List<Team> decodeList(String raw) =>
      (jsonDecode(raw) as List).map((e) => Team.fromJson(e)).toList();

  static String? _nullableString(dynamic value) {
    final text = (value ?? '').toString();
    return text.isEmpty ? null : text;
  }

  static int? _nullableInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }
}
