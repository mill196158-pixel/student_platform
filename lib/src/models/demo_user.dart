class DemoUser {
  final String firstName;
  final String lastName;

  /// ВУЗ и курс (строка с номером: "1", "2" и т.д.)
  final String university;
  final String group; // используем как "курс"

  /// Статус/интро
  final String status;

  /// Статистика
  final int messagesCount;
  final int friendsCount;

  /// Аватар: локальный путь (демо) или url (на будущее)
  final String? avatarPath;
  final String? avatarUrl;

  const DemoUser({
    required this.firstName,
    required this.lastName,
    required this.university,
    required this.group,
    required this.status,
    required this.messagesCount,
    required this.friendsCount,
    this.avatarPath,
    this.avatarUrl,
  });

  String get fullName =>
      [firstName, lastName].where((e) => e.trim().isNotEmpty).join(' ').trim();

  DemoUser copyWith({
    String? firstName,
    String? lastName,
    String? university,
    String? group,
    String? status,
    int? messagesCount,
    int? friendsCount,
    String? avatarPath,
    String? avatarUrl,
  }) {
    return DemoUser(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      university: university ?? this.university,
      group: group ?? this.group,
      status: status ?? this.status,
      messagesCount: messagesCount ?? this.messagesCount,
      friendsCount: friendsCount ?? this.friendsCount,
      avatarPath: avatarPath ?? this.avatarPath,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }

  factory DemoUser.demo() => const DemoUser(
        firstName: 'Иван',
        lastName: 'Иванов',
        university: 'СПбГАСУ',
        group: '1', // студент 1 курс
        status: 'Готовлюсь к сессии 💪',
        messagesCount: 42,
        friendsCount: 7,
        avatarPath: null,
        avatarUrl: null,
      );
}
