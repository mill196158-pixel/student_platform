class Assignment {
  final String id;
  final String title; // Название
  final String description; // Что сделать
  final String? link; // Ссылка (опц.)
  final String? due; // Срок (опц.)
  final DateTime? dueAt;
  final List<Map<String, String>> attachments; // [{name, path}]
  final bool published; // Опубликовано
  final int votes; // Голоса "за" для публикации
  final bool completedByMe; // Моя отметка выполнения
  final String createdBy; // 'me' | 'student' | 'starosta'
  final DateTime createdAt;
  final String? status;
  final DateTime? publishedAt;
  final String? subjectOfferingId;
  final String? groupId;
  final String? subjectId;
  final String? academicYearId;
  final String? academicTermId;
  final int? semesterNumber;

  int get votesCount => votes;

  const Assignment({
    required this.id,
    required this.title,
    required this.description,
    this.link,
    this.due,
    this.dueAt,
    this.attachments = const [],
    required this.published,
    required this.votes,
    required this.completedByMe,
    required this.createdBy,
    required this.createdAt,
    this.status,
    this.publishedAt,
    this.subjectOfferingId,
    this.groupId,
    this.subjectId,
    this.academicYearId,
    this.academicTermId,
    this.semesterNumber,
  });

  Assignment copyWith({
    String? id,
    String? title,
    String? description,
    String? link,
    String? due,
    DateTime? dueAt,
    List<Map<String, String>>? attachments,
    bool? published,
    int? votes,
    bool? completedByMe,
    String? createdBy,
    DateTime? createdAt,
    String? status,
    DateTime? publishedAt,
    String? subjectOfferingId,
    String? groupId,
    String? subjectId,
    String? academicYearId,
    String? academicTermId,
    int? semesterNumber,
  }) {
    return Assignment(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      link: link ?? this.link,
      due: due ?? this.due,
      dueAt: dueAt ?? this.dueAt,
      attachments: attachments ?? this.attachments,
      published: published ?? this.published,
      votes: votes ?? this.votes,
      completedByMe: completedByMe ?? this.completedByMe,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      publishedAt: publishedAt ?? this.publishedAt,
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
        'title': title,
        'description': description,
        'link': link,
        'due': due,
        'dueAt': dueAt?.toIso8601String(),
        'attachments': attachments,
        'published': published,
        'votes': votes,
        'completedByMe': completedByMe,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'status': status,
        'publishedAt': publishedAt?.toIso8601String(),
        'subjectOfferingId': subjectOfferingId,
        'groupId': groupId,
        'subjectId': subjectId,
        'academicYearId': academicYearId,
        'academicTermId': academicTermId,
        'semesterNumber': semesterNumber,
      };

  factory Assignment.fromJson(Map<String, dynamic> j) => Assignment(
        id: j['id'],
        title: j['title'],
        description: j['description'] ?? '',
        link: j['link'],
        due: j['due'],
        dueAt: _nullableDate(j['dueAt'] ?? j['due_at']),
        attachments: (j['attachments'] as List?)
                ?.map((e) => (e as Map).map((k, v) => MapEntry('$k', '$v')))
                .toList() ??
            const [],
        published: (j['published'] ?? false) as bool,
        votes: _asInt(j['votes'] ?? j['votesCount'] ?? j['votes_count']) ?? 0,
        completedByMe:
            (j['completedByMe'] ?? j['completed_by_me'] ?? false) == true,
        createdBy: j['createdBy'] ?? 'student',
        createdAt:
            _nullableDate(j['createdAt'] ?? j['created_at']) ?? DateTime.now(),
        status: _nullableString(j['status']),
        publishedAt: _nullableDate(j['publishedAt'] ?? j['published_at']),
        subjectOfferingId:
            _nullableString(j['subjectOfferingId'] ?? j['subject_offering_id']),
        groupId: _nullableString(j['groupId'] ?? j['group_id']),
        subjectId: _nullableString(j['subjectId'] ?? j['subject_id']),
        academicYearId:
            _nullableString(j['academicYearId'] ?? j['academic_year_id']),
        academicTermId:
            _nullableString(j['academicTermId'] ?? j['academic_term_id']),
        semesterNumber: _asInt(j['semesterNumber'] ?? j['semester_number']),
      );

  static String? _nullableString(dynamic value) {
    final text = (value ?? '').toString();
    return text.isEmpty ? null : text;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  static DateTime? _nullableDate(dynamic value) {
    final text = (value ?? '').toString();
    return text.isEmpty ? null : DateTime.tryParse(text);
  }
}
