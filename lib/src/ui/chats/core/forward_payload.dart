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
        't':
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
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
        .map(
            (e) => ForwardFileRef.fromJson(Map<String, dynamic>.from(e as Map)))
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

  /// Human-readable preview. Nested payloads stay serialized in the message;
  /// their wire format must never be shown in the composer.
  String? composerPreview() {
    if (items.isEmpty) return null;
    final first = items.first;
    final author =
        first.authorName.trim().isEmpty ? 'Сообщение' : first.authorName.trim();
    final text = _previewText(first.text);
    if (text.isNotEmpty) return '$author: $text';
    if (first.files.isNotEmpty) {
      final name = first.files.first.name.trim();
      return '$author: ${name.isEmpty ? 'вложение' : name}';
    }
    return author;
  }

  /// Text safe to display when a message may contain a forwarded payload.
  static String displayText(String source) => _previewText(source);

  static String _previewText(String source, [int depth = 0]) {
    final text = source.trim();
    final marker = text.indexOf('__FG__:');
    if (marker < 0) return text.replaceAll(RegExp(r'\s+'), ' ');
    final prefix = text.substring(0, marker).trim();
    if (prefix.isNotEmpty) return prefix.replaceAll(RegExp(r'\s+'), ' ');
    if (depth >= 8) return 'Пересланное сообщение';
    final nested = tryParse(text.substring(marker));
    if (nested == null) return 'Пересланное сообщение';
    final caption = _previewText(nested.caption ?? '', depth + 1);
    if (caption.isNotEmpty) return caption;
    if (nested.items.isEmpty) return 'Пересланное сообщение';
    final first = nested.items.first;
    final body = _previewText(first.text, depth + 1);
    if (body.isNotEmpty) return body;
    if (first.files.isNotEmpty) {
      final name = first.files.first.name.trim();
      return name.isEmpty ? 'Вложение' : name;
    }
    return 'Пересланное сообщение';
  }

  List<ForwardFileRef> allFiles([int depth = 0]) {
    if (depth > 8) throw StateError('Слишком много вложенных пересылок.');
    return [
      for (final item in items) ...[
        ...item.files,
        if (isForwardText(item.text))
          ...?tryParse(item.text)?.allFiles(depth + 1),
      ]
    ];
  }

  /// A cross-chat forward owns independent uploads in the destination chat.
  /// Never retain source-only URLs in the visible forward payload.
  ForwardPayload withCopiedFiles(Map<String, ForwardFileRef> copies,
      [int depth = 0]) {
    if (depth > 8) throw StateError('Слишком много вложенных пересылок.');
    return ForwardPayload(
        fromChatId: fromChatId,
        caption: caption,
        items: items.map((item) {
          final nested = isForwardText(item.text) ? tryParse(item.text) : null;
          return ForwardItem(
              messageId: item.messageId,
              authorId: item.authorId,
              authorName: item.authorName,
              authorAvatarUrl: item.authorAvatarUrl,
              at: item.at,
              text: nested == null
                  ? item.text
                  : nested.withCopiedFiles(copies, depth + 1).encodeForText(),
              files: item.files.map((file) {
                final copy = copies[file.url];
                if (copy == null)
                  throw StateError('Не все вложения готовы к пересылке.');
                return copy;
              }).toList());
        }).toList());
  }

  static bool isForwardText(String text) => text.startsWith('__FG__:');

  static ForwardPayload? tryParse(String? text) {
    if (text == null || !isForwardText(text)) return null;

    try {
      final raw = text.substring('__FG__:'.length);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final items = (json['items'] as List? ?? const [])
          .map((e) => ForwardItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final fromChatId =
          (json['from'] ?? json['from_chat_id'] ?? '').toString();
      final caption = (json['caption'] ?? json['cap']) as String?;

      return ForwardPayload(
        fromChatId: fromChatId,
        caption: caption,
        items: items,
      );
    } catch (_) {
      return null;
    }
  }
}
