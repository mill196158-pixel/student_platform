class PushPayload {
  const PushPayload({
    required this.version,
    required this.type,
    this.notificationId,
    this.chatId,
    this.peerId,
    this.teamId,
    this.assignmentId,
    this.lessonId,
    this.friendUserId,
    this.raw = const {},
  });

  final int version;
  final String type;
  final String? notificationId;
  final String? chatId;
  final String? peerId;
  final String? teamId;
  final String? assignmentId;
  final String? lessonId;
  final String? friendUserId;
  final Map<String, String> raw;

  static PushPayload? tryParse(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return null;

    final normalized = <String, String>{};
    for (final entry in data.entries) {
      final value = entry.value;
      if (value == null) continue;
      normalized[entry.key] = value.toString();
    }

    final type = (normalized['type'] ?? '').trim();
    if (type.isEmpty) return null;

    final version = int.tryParse(normalized['version'] ?? '1') ?? 1;

    return PushPayload(
      version: version,
      type: type,
      notificationId: _nonEmpty(normalized['notification_id']),
      chatId: _nonEmpty(normalized['chat_id']),
      peerId: _nonEmpty(normalized['peer_id']),
      teamId: _nonEmpty(normalized['team_id']),
      assignmentId: _nonEmpty(normalized['assignment_id']),
      lessonId: _nonEmpty(normalized['lesson_id']),
      friendUserId: _nonEmpty(normalized['friend_user_id']),
      raw: normalized,
    );
  }

  String get dedupeKey {
    final id = notificationId;
    if (id != null && id.isNotEmpty) return 'n:$id';
    return 't:$type|c:${chatId ?? ''}|a:${assignmentId ?? ''}|l:${lessonId ?? ''}|f:${friendUserId ?? ''}';
  }

  static String? _nonEmpty(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }
}
