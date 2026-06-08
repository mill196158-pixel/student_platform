import 'dart:convert';

class ForwardFileRef {
  final String? id;
  final String url;
  final String name;
  final String type;
  final int size;

  const ForwardFileRef({
    this.id,
    required this.url,
    required this.name,
    required this.type,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        if (id != null && id!.isNotEmpty) 'fid': id,
        'url': url,
        'name': name,
        'type': type,
        'size': size,
      };

  factory ForwardFileRef.fromJson(Map<String, dynamic> json) {
    return ForwardFileRef(
      id: ((json['fid'] ?? json['file_id'] ?? json['id']) ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      type: (json['type'] ?? 'application/octet-stream').toString(),
      size: (json['size'] ?? 0) as int,
    );
  }
}

class ForwardItem {
  final String messageId;
  final String authorId;
  final String authorName;
  final String? authorAvatarUrl;
  final DateTime at;
  final String text;
  final List<ForwardFileRef> files;

  const ForwardItem({
    required this.messageId,
    required this.authorId,
    required this.authorName,
    this.authorAvatarUrl,
    required this.at,
    required this.text,
    required this.files,
  });

  Map<String, dynamic> toJson() => {
        'id': messageId,
        'at': at.toIso8601String(),
        'aid': authorId,
        'a': authorName,
        'ava': authorAvatarUrl,
        't': '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
        'x': text,
        'f': files.map((e) => e.toJson()).toList(),
      };

  factory ForwardItem.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['mid'] ?? '').toString();
    final authorId = (json['aid'] ?? '').toString();
    final authorName = (json['a'] ?? json['an'] ?? '').toString();
    final authorAvatarUrl = json['ava'] as String?;
    final atIso = (json['at'] ?? '').toString();
    final body = (json['x'] ?? json['text'] ?? '').toString();
    final files = (json['f'] as List? ?? const [])
        .map((e) => ForwardFileRef.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    return ForwardItem(
      messageId: id,
      authorId: authorId,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      at: DateTime.tryParse(atIso) ?? DateTime.now(),
      text: body,
      files: files,
    );
  }
}

class ForwardPayload {
  final String fromChatId;
  final String? caption;
  final List<ForwardItem> items;

  const ForwardPayload({
    required this.fromChatId,
    this.caption,
    required this.items,
  });

  Map<String, dynamic> toJson() => {
        'fg': 1,
        'from': fromChatId,
        'items': items.map((e) => e.toJson()).toList(),
        if (caption != null && caption!.isNotEmpty) 'caption': caption,
      };

  String encodeForText() => '__FG__:${jsonEncode(toJson())}';

  static bool isForwardText(String text) => text.startsWith('__FG__:');

  static ForwardPayload? tryParse(String? text) {
    if (text == null || !isForwardText(text)) return null;

    final raw = text.substring('__FG__:'.length);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final items = (json['items'] as List? ?? const [])
        .map((e) => ForwardItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final fromChatId = (json['from'] ?? json['from_chat_id'] ?? '').toString();
    final caption = (json['caption'] ?? json['cap']) as String?;

    return ForwardPayload(
      fromChatId: fromChatId,
      caption: caption,
      items: items,
    );
  }
}
