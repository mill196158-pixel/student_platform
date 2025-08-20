// =============================
// FILE: lib/src/ui/learning/models/message.dart
// =============================

enum MessageType { text, assignmentDraft, assignmentPublished }

class Message {
  final String id;
  final String chatId;        // UUID чата (может быть пустым в оптимистичных локальных сообщениях)
  final String authorId;      // UUID автора из БД (пустая строка для system)
  final String authorLogin;   // логин (например, 13015) или 'system'
  final String authorName;    // имя для отображения
  final String text;          // контент сообщения
  final DateTime at;          // created_at

  // опционально
  final String? authorAvatarUrl; // URL аватарки автора (из users.avatar_url)
  final String? imagePath;       // путь к локальной картинке/вложению (клиент)
  final String? replyToId;       // id сообщения, на которое был ответ
  final String? assignmentId;    // для карточек заданий
  final MessageType type;        // msg_type

  const Message({
    required this.id,
    required this.chatId,
    required this.authorId,
    required this.authorLogin,
    required this.authorName,
    required this.text,
    required this.at,
    this.authorAvatarUrl,
    this.imagePath,
    this.replyToId,
    this.assignmentId,
    this.type = MessageType.text,
  });

  bool isMine(String? currentUid) =>
      currentUid != null && currentUid.isNotEmpty && currentUid == authorId;

  bool get isSystem => authorLogin.toLowerCase() == 'system' || authorId.isEmpty;

  Message copyWith({
    String? id,
    String? chatId,
    String? authorId,
    String? authorLogin,
    String? authorName,
    String? text,
    DateTime? at,
    String? authorAvatarUrl,
    String? imagePath,
    String? replyToId,
    String? assignmentId,
    MessageType? type,
  }) {
    return Message(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      authorId: authorId ?? this.authorId,
      authorLogin: authorLogin ?? this.authorLogin,
      authorName: authorName ?? this.authorName,
      text: text ?? this.text,
      at: at ?? this.at,
      authorAvatarUrl: authorAvatarUrl ?? this.authorAvatarUrl,
      imagePath: imagePath ?? this.imagePath,
      replyToId: replyToId ?? this.replyToId,
      assignmentId: assignmentId ?? this.assignmentId,
      type: type ?? this.type,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'chat_id': chatId,
        'author_id': authorId,
        'author_login': authorLogin,
        'author_name': authorName,
        'content': text,
        'created_at': at.toIso8601String(),
        'author_avatar_url': authorAvatarUrl,
        'imagePath': imagePath,
        'replyToId': replyToId,
        'assignmentId': assignmentId,
        'msg_type': type.name,
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: (j['id'] ?? '').toString(),
        chatId: (j['chat_id'] ?? '').toString(),
        authorId: (j['author_id'] ?? '').toString(),
        authorLogin: (j['author_login'] ?? '').toString(),
        authorName: (j['author_name'] ?? 'Студент').toString(),
        text: (j['content'] ?? j['text'] ?? '').toString(),
        at: DateTime.tryParse((j['created_at'] ?? j['at'] ?? '').toString()) ??
            DateTime.now(),
        authorAvatarUrl: (j['author_avatar_url'] ??
                j['avatar_url'] ??
                j['authorAvatarUrl'])
            ?.toString(),
        imagePath: (j['imagePath'] ?? j['image_path'])?.toString(),
        replyToId: (j['replyToId'] ?? j['reply_to_id'])?.toString(),
        assignmentId: j['assignmentId']?.toString(),
        type: _parseType(j['msg_type'] ?? j['type']),
      );

  static MessageType _parseType(dynamic s) {
    if (s is String) {
      return MessageType.values.firstWhere(
        (e) => e.name == s,
        orElse: () => MessageType.text,
      );
    }
    return MessageType.text;
  }
}
