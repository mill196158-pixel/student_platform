import 'dart:convert';

class Team {
  final String id;
  final String name;       // Название команды/предмета
  final String teacher;    // Преподаватель
  final String groupCode;  // Группа/курс привязки
  final String icon;       // Эмодзи/краткая метка в аватаре
  final int  unread;       // Непрочитанные (демо)
  final bool pollApproved; // Разрешены "Задания" после голосования

  const Team({
    required this.id,
    required this.name,
    required this.teacher,
    required this.groupCode,
    required this.icon,
    this.unread = 0,
    this.pollApproved = false,
  });

  Team copyWith({
    String? id,
    String? name,
    String? teacher,
    String? groupCode,
    String? icon,
    int? unread,
    bool? pollApproved,
  }) {
    return Team(
      id: id ?? this.id,
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      groupCode: groupCode ?? this.groupCode,
      icon: icon ?? this.icon,
      unread: unread ?? this.unread,
      pollApproved: pollApproved ?? this.pollApproved,
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
  };

  factory Team.fromJson(Map<String, dynamic> j) => Team(
    id: j['id'] as String,
    name: j['name'] as String,
    teacher: j['teacher'] as String,
    groupCode: j['groupCode'] as String,
    icon: j['icon'] as String,
    unread: (j['unread'] ?? 0) as int,
    pollApproved: (j['pollApproved'] ?? false) as bool,
  );

  static String encodeList(List<Team> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  static List<Team> decodeList(String raw) =>
      (jsonDecode(raw) as List).map((e) => Team.fromJson(e)).toList();
}
