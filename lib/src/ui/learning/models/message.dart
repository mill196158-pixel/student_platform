// =============================
// FILE: lib/src/ui/learning/models/message.dart
// =============================

import 'dart:convert';
import 'chat_file.dart';

enum MessageType { text, file, assignmentDraft, assignmentPublished, forward }

enum MessageDeliveryStatus { sent, sending, failed }

// ==== Forward models (общая для ДМ и групп) ====
class ForwardAttachmentModel {
  final String? id;
  final String url;
  final String? name;
  final String? mime;
  final int? size;
  ForwardAttachmentModel({
    this.id,
    required this.url,
    this.name,
    this.mime,
    this.size,
  });
  factory ForwardAttachmentModel.fromJson(Map<String, dynamic> j) =>
      ForwardAttachmentModel(
        id: (j['id'] ?? j['file_id'] ?? j['fid'])?.toString(),
        url: (j['url'] ?? '').toString(),
        name: j['name'] as String?,
        mime: j['mime'] as String?,
        size: (j['size'] is int)
            ? j['size'] as int
            : int.tryParse((j['size'] ?? '').toString()),
      );
}

class ForwardItemModel {
  final String id;
  final String authorId;
  final String authorName;
  final DateTime at;
  final String? text;
  final List<ForwardAttachmentModel> attachments;
  ForwardItemModel({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.at,
    this.text,
    this.attachments = const [],
  });
  factory ForwardItemModel.fromJson(Map<String, dynamic> j) => ForwardItemModel(
        id: (j['id'] ?? '').toString(),
        authorId: (j['author_id'] ?? '').toString(),
        authorName: (j['author_name'] ?? '').toString(),
        at: DateTime.tryParse((j['created_at'] ?? '').toString()) ??
            DateTime.now(),
        text: (j['text'] ?? '')?.toString(),
        attachments: ((j['attachments'] ?? const []) as List)
            .map((x) => ForwardAttachmentModel.fromJson(
                Map<String, dynamic>.from(x as Map)))
            .toList(),
      );
}

class ForwardPayloadModel {
  final String fromChatId;
  final String? fromChatTitle;
  final List<ForwardItemModel> items;
  ForwardPayloadModel(
      {required this.fromChatId, this.fromChatTitle, required this.items});
  factory ForwardPayloadModel.fromJson(Map<String, dynamic> j) {
    final root = j.containsKey('forward')
        ? Map<String, dynamic>.from(j['forward'] as Map)
        : j;
    return ForwardPayloadModel(
      fromChatId: (root['from_chat_id'] ?? '').toString(),
      fromChatTitle: root['from_chat_title'] as String?,
      items: ((root['items'] ?? const []) as List)
          .map((x) =>
              ForwardItemModel.fromJson(Map<String, dynamic>.from(x as Map)))
          .toList(),
    );
  }
}

class Message {
  final String id;
  final String
      chatId; // UUID чата (может быть пустым в оптимистичных локальных сообщениях)
  final String authorId; // UUID автора из БД (пустая строка для system)
  final String authorLogin; // логин (например, 13015) или 'system'
  final String authorName; // имя для отображения
  final String text; // контент сообщения
  final DateTime at; // created_at

  // опционально
  final String? authorAvatarUrl; // URL аватарки автора (из users.avatar_url)
  final String? imagePath; // путь к локальной картинке/вложению (клиент)
  final String? replyToId; // id сообщения, на которое был ответ
  final String? assignmentId; // для карточек заданий
  final String? fileId; // ID файла в чате
  final MessageType type; // msg_type
  final List<ChatFile>? attachments; // связанные файлы для мульти-отправки
  final bool isPinned; // серверный флаг закрепа
  final Map<String, int>? reactions; // emoji -> count
  final List<String>? userReactions; // emojis current user reacted with
  final ForwardPayloadModel? forward; // payload пересылки
  final String? clientId; // локальный id optimistic-сообщения
  final MessageDeliveryStatus deliveryStatus;

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
    this.fileId,
    this.type = MessageType.text,
    this.attachments,
    this.isPinned = false,
    this.reactions,
    this.userReactions,
    this.forward,
    this.clientId,
    this.deliveryStatus = MessageDeliveryStatus.sent,
  });

  bool isMine(String? currentUid) =>
      currentUid != null && currentUid.isNotEmpty && currentUid == authorId;

  bool get isSystem =>
      authorLogin.toLowerCase() == 'system' || authorId.isEmpty;
  bool get isLocal =>
      clientId != null ||
      id.startsWith('local_') ||
      deliveryStatus != MessageDeliveryStatus.sent;
  bool get isSending => deliveryStatus == MessageDeliveryStatus.sending;
  bool get isFailed => deliveryStatus == MessageDeliveryStatus.failed;

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
    String? fileId,
    MessageType? type,
    List<ChatFile>? attachments,
    bool? isPinned,
    Map<String, int>? reactions,
    List<String>? userReactions,
    ForwardPayloadModel? forward,
    String? clientId,
    MessageDeliveryStatus? deliveryStatus,
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
      fileId: fileId ?? this.fileId,
      type: type ?? this.type,
      attachments: attachments ?? this.attachments,
      isPinned: isPinned ?? this.isPinned,
      reactions: reactions ?? this.reactions,
      userReactions: userReactions ?? this.userReactions,
      forward: forward ?? this.forward,
      clientId: clientId ?? this.clientId,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
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
        'fileId': fileId,
        'msg_type': type.name,
        'attachments': attachments?.map((e) => e.toJson()).toList(),
        'is_pinned': isPinned,
        'reactions': reactions,
        'client_id': clientId,
        'delivery_status': deliveryStatus.name,
      };

  factory Message.fromJson(Map<String, dynamic> j) {
    String rawType = (j['msg_type'] ?? j['type'] ?? 'text').toString();
    // defensive: detect forward by content shape if msg_type missing
    if (rawType == 'text') {
      try {
        final c = (j['content'] ?? '').toString();
        final s = c.trimLeft();
        if (s.startsWith('{')) {
          final m = jsonDecode(s);
          if (m is Map && (m['forward'] != null || m['from_chat_id'] != null)) {
            rawType = 'forward';
          }
        }
      } catch (_) {}
    }
    MessageType t;
    switch (rawType) {
      case 'file':
        t = MessageType.file;
        break;
      case 'assignmentDraft':
        t = MessageType.assignmentDraft;
        break;
      case 'assignmentPublished':
        t = MessageType.assignmentPublished;
        break;
      case 'forward':
        t = MessageType.forward;
        break;
      default:
        t = MessageType.text;
    }

    ForwardPayloadModel? fwd;
    String textVal = (j['body'] ?? '').toString();
    if (t == MessageType.forward) {
      final content = (j['content'] ?? '').toString();
      if (content.isNotEmpty) {
        try {
          final map = jsonDecode(content) as Map<String, dynamic>;
          fwd = ForwardPayloadModel.fromJson(map);
          // keep textVal from body (usually empty) to avoid showing JSON
        } catch (_) {}
      }
      if (textVal.isEmpty) {
        textVal = '';
      }
    } else if (textVal.isEmpty) {
      textVal = (j['content'] ?? j['text'] ?? '').toString();
    }

    final authorName = (j['author_name'] ?? '').toString().trim();
    final authorLogin = (j['author_login'] ?? '').toString().trim();

    return Message(
      id: (j['id'] ?? '').toString(),
      chatId: (j['chat_id'] ?? '').toString(),
      authorId: (j['author_id'] ?? '').toString(),
      authorLogin: authorLogin,
      authorName: authorName.isNotEmpty
          ? authorName
          : (authorLogin.isNotEmpty ? authorLogin : 'Студент'),
      text: textVal,
      at: DateTime.tryParse((j['created_at'] ?? j['at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      authorAvatarUrl:
          (j['author_avatar_url'] ?? j['avatar_url'] ?? j['authorAvatarUrl'])
              ?.toString(),
      imagePath: (j['imagePath'] ?? j['image_path'])?.toString(),
      replyToId: (j['replyToId'] ?? j['reply_to_id'])?.toString(),
      assignmentId: (j['assignment_id'] ?? j['assignmentId'])?.toString(),
      fileId: (j['file_id'] ?? j['fileId'])?.toString(),
      type: t,
      attachments: _parseAttachments(j['attachments']),
      isPinned: (j['is_pinned'] ?? false) == true,
      reactions: _parseReactions(j['reactions']),
      userReactions: _parseUserReactions(j['user_reactions']),
      forward: fwd,
      clientId: (j['client_id'] ?? j['clientId'])?.toString(),
      deliveryStatus: _parseDeliveryStatus(j['delivery_status']),
    );
  }

  static MessageDeliveryStatus _parseDeliveryStatus(dynamic value) {
    final raw = (value ?? '').toString();
    for (final status in MessageDeliveryStatus.values) {
      if (status.name == raw) return status;
    }
    return MessageDeliveryStatus.sent;
  }

  static List<ChatFile>? _parseAttachments(dynamic attachments) {
    if (attachments == null) return null;

    if (attachments is List) {
      return attachments
          .whereType<Map>()
          .map((item) => ChatFile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }

    if (attachments is Map) {
      return [ChatFile.fromJson(Map<String, dynamic>.from(attachments))];
    }

    return null;
  }

  static Map<String, int>? _parseReactions(dynamic r) {
    try {
      if (r == null) return null;
      if (r is Map) {
        final map = <String, int>{};
        r.forEach((k, v) {
          try {
            final cnt = v is int ? v : int.parse(v.toString());
            map[k.toString()] = cnt;
          } catch (_) {}
        });
        return map.isEmpty ? null : map;
      }
      if (r is String && r.isNotEmpty) {
        final decoded = jsonDecode(r) as Map<String, dynamic>;
        final map = <String, int>{};
        decoded.forEach((k, v) {
          try {
            final cnt = v is int ? v : int.parse(v.toString());
            map[k] = cnt;
          } catch (_) {}
        });
        return map.isEmpty ? null : map;
      }
    } catch (_) {}
    return null;
  }

  static List<String>? _parseUserReactions(dynamic ur) {
    try {
      if (ur == null) return null;
      if (ur is List) {
        return ur.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
      if (ur is String && ur.isNotEmpty) {
        final decoded = jsonDecode(ur) as List<dynamic>;
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return null;
  }
}
