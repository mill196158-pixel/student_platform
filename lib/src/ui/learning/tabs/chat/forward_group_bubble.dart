// =============================
// FILE: lib/src/ui/learning/tabs/chat/forward_group_bubble.dart
// =============================

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/chat_file.dart';
import '../../models/message.dart';

import 'profile_avatar.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';

String _fmtIsoLocal(String iso, {bool long = false}) {
  try {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    final d = '${two(dt.day)}.${two(dt.month)}.${dt.year}';
    final t = '${two(dt.hour)}:${two(dt.minute)}';
    return long ? '$d $t' : '$t · $d';
  } catch (_) {
    return '';
  }
}

/// Бабл пересланной пачки сообщений.
/// message.text содержит спец-пэйлоад вида:
/// "__FG__:{ fg:1, items:[{id,aid,a,ava,t,x,f:[]}, ...], caption:'...' }"
class ForwardGroupBubble extends StatelessWidget {
  final Message message; // контейнер "__FG__"
  final String time; // время этого сообщения
  final bool isMe;
  final bool selected;
  final Map<String, ChatFile> idToFile; // файлы, подвязанные к данному message
  final void Function(String srcMessageId)? onOpenOriginal;
  final VoidCallback? onLongPress;
  final VoidCallback? onReact;
  final Map<String, int>? reactions;

  const ForwardGroupBubble({
    super.key,
    required this.message,
    required this.time,
    required this.isMe,
    required this.idToFile,
    this.selected = false,
    this.onOpenOriginal,
    this.onLongPress,
    this.onReact,
    this.reactions,
  });

  static const _mark = '__FG__:';

  /// Извлекаем JSON-пакет безопасно.
  /// Поддерживаем варианты, если кто-то по ошибке приписал текст до/после.
  Map<String, dynamic>? _parsePayload(String raw) {
    if (raw.isEmpty) return null;
    final idx = raw.lastIndexOf(_mark);
    if (idx < 0) return null;
    final jsonPart = raw.substring(idx + _mark.length).trim();
    if (jsonPart.isEmpty) return null;
    try {
      final decoded = json.decode(jsonPart);
      if (decoded is Map && decoded['fg'] == 1)
        return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final fg = _parsePayload(message.text);
    if (fg == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final items = List<Map<String, dynamic>>.from(fg['items'] ?? const []);
    final caption = (fg['caption'] as String?)?.trim() ?? '';

    final baseBg = isMe
        ? theme.colorScheme.primary.withValues(alpha: 0.22)
        : theme.colorScheme.surfaceContainerHighest;
    final bg =
        selected ? Colors.white.withValues(alpha: isMe ? 0.85 : 0.78) : baseBg;
    const textColor = Colors.black87;

    return GestureDetector(
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.black12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Заголовок
              Row(
                children: const [
                  Icon(Icons.forward, size: 16, color: textColor),
                  SizedBox(width: 6),
                  Text(
                    'Пересланные сообщения',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Элементы пересылки
              ...items.map((m) => _ForwardItem(
                    map: m,
                    idToFile: idToFile,
                    onOpenOriginal: onOpenOriginal,
                  )),

              if (caption.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  caption,
                  style: const TextStyle(
                      color: textColor,
                      fontStyle: FontStyle.italic,
                      height: 1.22),
                ),
              ],

              Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  time,
                  style: const TextStyle(color: textColor, fontSize: 11),
                ),
              ),

              if (reactions != null && reactions!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: reactions!.entries.map((e) {
                    return GestureDetector(
                      onTap: onReact,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color:
                              Colors.black.withValues(alpha: isMe ? .15 : .08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text('${e.key} ${e.value}',
                            style: const TextStyle(
                                color: textColor, fontSize: 12)),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ForwardItem extends StatelessWidget {
  final Map<String, dynamic> map;
  final Map<String, ChatFile> idToFile;
  final void Function(String srcMessageId)? onOpenOriginal;

  const _ForwardItem({
    required this.map,
    required this.idToFile,
    this.onOpenOriginal,
  });

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    const textColor = Colors.black87;

    final srcId = (map['id'] ?? '').toString();
    final authorId = (map['aid'] ?? '').toString();
    final author = (map['a'] ?? '').toString();
    final ava = (map['ava'] ?? '').toString();
    final timeStr = (map['t'] ?? '').toString();
    final atIso = (map['at'] ?? '').toString();
    final pretty = atIso.isNotEmpty ? _fmtIsoLocal(atIso) : timeStr;
    final prettyLong = atIso.isNotEmpty ? _fmtIsoLocal(atIso, long: true) : '';

    final body = (map['x'] ?? '').toString();
    final rawF = (map['f'] as List?) ?? const [];
    final fileIds = rawF.whereType<String>().toList();
    final fileObjs =
        rawF.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withValues(alpha: .08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: authorId.isNotEmpty
                    ? () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  FriendProfileScreen(userId: authorId)),
                        )
                    : null,
                child: ProfileAvatar(name: author, imageUrl: ava),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pretty.isEmpty ? author : '$author • $pretty',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: textColor),
                ),
              ),
              if (srcId.isNotEmpty && onOpenOriginal != null)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.open_in_new,
                      size: 16, color: Colors.black54),
                  tooltip: 'Перейти к исходному',
                  onPressed: () => onOpenOriginal!(srcId),
                ),
            ],
          ),
          if (body.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: (srcId.isNotEmpty && onOpenOriginal != null)
                  ? () => onOpenOriginal!(srcId)
                  : null,
              child: Text(body,
                  style: const TextStyle(color: textColor, height: 1.22)),
            ),
          ],
          if (fileIds.isNotEmpty || fileObjs.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ForwardFilesList(
              ids: fileIds,
              idToFile: idToFile,
              fileObjects: fileObjs,
              onOpenUrl: _openUrl,
            ),
          ],
          if (prettyLong.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Исходное: $prettyLong',
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ],
      ),
    );
  }
}

class _ForwardFilesList extends StatelessWidget {
  final List<String> ids;
  final Map<String, ChatFile> idToFile;
  final List<Map<String, dynamic>>? fileObjects;
  final Future<void> Function(String url)? onOpenUrl;

  const _ForwardFilesList({
    required this.ids,
    required this.idToFile,
    this.fileObjects,
    this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    final files = ids.map((id) => idToFile[id]).whereType<ChatFile>().toList();
    if (files.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final file in files)
            _ForwardFileChip(
              name: file.fileName,
              type: file.fileType,
              size: file.fileSize,
              url: file.fileUrl,
              onOpenUrl: onOpenUrl,
            ),
        ],
      );
    }

    final objs = (fileObjects ?? const <Map<String, dynamic>>[]);
    if (objs.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: objs.map((o) {
          final name = (o['name'] ?? 'Вложение').toString();
          final type = (o['type'] ?? '').toString();
          final url = (o['url'] ?? '').toString();
          final size = int.tryParse((o['size'] ?? '').toString()) ?? 0;
          return _ForwardFileChip(
            name: name,
            type: type,
            size: size,
            url: url,
            onOpenUrl: onOpenUrl,
          );
        }).toList(),
      );
    }

    return const SizedBox.shrink();
  }
}

class _ForwardFileChip extends StatelessWidget {
  final String name;
  final String type;
  final int size;
  final String url;
  final Future<void> Function(String url)? onOpenUrl;

  const _ForwardFileChip({
    required this.name,
    required this.type,
    required this.size,
    required this.url,
    this.onOpenUrl,
  });

  bool get _isImage => type.startsWith('image/');
  bool get _isPdf =>
      type.contains('pdf') || name.toLowerCase().endsWith('.pdf');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canOpen = url.isNotEmpty && onOpenUrl != null;
    final icon = _isImage
        ? Icons.image_outlined
        : _isPdf
            ? Icons.picture_as_pdf_outlined
            : Icons.insert_drive_file_outlined;
    final displayName = name.trim().isEmpty ? 'Вложение' : name.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.white.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: canOpen ? () => onOpenUrl?.call(url) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black.withValues(alpha: .08)),
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: .13),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 18, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (size > 0) _formatSize(size),
                          canOpen ? 'Нажмите, чтобы открыть' : 'Файл',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: .56),
                          fontSize: 10.5,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canOpen) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 15,
                    color: Colors.black.withValues(alpha: .46),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
