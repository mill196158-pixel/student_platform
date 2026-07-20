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

  /// Query-string payload for local notification taps (kept small for OS limits).
  String toLocalPayload() {
    final map = <String, String>{
      'version': '$version',
      'type': type,
      if (notificationId != null) 'notification_id': notificationId!,
      if (chatId != null) 'chat_id': chatId!,
      if (peerId != null) 'peer_id': peerId!,
      if (teamId != null) 'team_id': teamId!,
      if (assignmentId != null) 'assignment_id': assignmentId!,
      if (lessonId != null) 'lesson_id': lessonId!,
      if (friendUserId != null) 'friend_user_id': friendUserId!,
      if (raw['title'] != null) 'title': raw['title']!,
      if (raw['body'] != null) 'body': raw['body']!,
    };
    final encoded = map.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return encoded.length > 3500
        ? 'type=${Uri.encodeComponent(type)}&chat_id=${Uri.encodeComponent(chatId ?? '')}'
        : encoded;
  }

  static PushPayload? tryParseLocalPayload(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final trimmed = raw.trim();
    if (!trimmed.contains('=')) return null;
    final map = <String, dynamic>{};
    for (final part in trimmed.split('&')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final k = Uri.decodeComponent(part.substring(0, idx));
      final v = Uri.decodeComponent(part.substring(idx + 1));
      if (k.isNotEmpty) map[k] = v;
    }
    return tryParse(map);
  }

  static String? _nonEmpty(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }
}
