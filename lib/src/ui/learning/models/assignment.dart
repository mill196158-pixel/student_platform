class Assignment {
  final String id;
  final String title;          // Название
  final String description;    // Что сделать
  final String? link;          // Ссылка (опц.)
  final String? due;           // Срок (опц.)
  final List<Map<String, String>> attachments; // [{name, path}]
  final bool published;        // Опубликовано
  final int votes;             // Голоса "за" для публикации
  final bool completedByMe;    // Моя отметка выполнения
  final String createdBy;      // 'me' | 'student' | 'starosta'
  final DateTime createdAt;

  const Assignment({
    required this.id,
    required this.title,
    required this.description,
    this.link,
    this.due,
    this.attachments = const [],
    required this.published,
    required this.votes,
    required this.completedByMe,
    required this.createdBy,
    required this.createdAt,
  });

  Assignment copyWith({
    String? id,
    String? title,
    String? description,
    String? link,
    String? due,
    List<Map<String, String>>? attachments,
    bool? published,
    int? votes,
    bool? completedByMe,
    String? createdBy,
    DateTime? createdAt,
  }) {
    return Assignment(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      link: link ?? this.link,
      due: due ?? this.due,
      attachments: attachments ?? this.attachments,
      published: published ?? this.published,
      votes: votes ?? this.votes,
      completedByMe: completedByMe ?? this.completedByMe,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'link': link,
        'due': due,
        'attachments': attachments,
        'published': published,
        'votes': votes,
        'completedByMe': completedByMe,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Assignment.fromJson(Map<String, dynamic> j) => Assignment(
        id: j['id'],
        title: j['title'],
        description: j['description'] ?? '',
        link: j['link'],
        due: j['due'],
        attachments: (j['attachments'] as List?)
                ?.map((e) => (e as Map).map((k, v) => MapEntry('$k', '$v')))
                .toList() ??
            const [],
        published: (j['published'] ?? false) as bool,
        votes: (j['votes'] ?? 0) as int,
        completedByMe: (j['completedByMe'] ?? false) as bool,
        createdBy: j['createdBy'] ?? 'student',
        createdAt: DateTime.parse(j['createdAt']),
      );
}
