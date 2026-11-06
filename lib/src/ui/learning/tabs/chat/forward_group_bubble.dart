// =============================
// FILE: lib/src/ui/learning/tabs/chat/forward_group_bubble.dart
// =============================

import 'dart:convert';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../models/chat_file.dart';
import '../../models/message.dart';
import '../../widgets/fullscreen_image.dart';

import 'profile_avatar.dart';
import 'forward_author_label.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';

const _forwardGroupMark = '__FG__:';

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

/// Извлекаем JSON-пакет безопасно.
/// Поддерживаем текст до маркера и не ломаемся на вложенных "__FG__" внутри JSON.
Map<String, dynamic>? _parseForwardPayload(String raw) {
  if (raw.isEmpty) return null;

  var searchFrom = 0;
  while (searchFrom < raw.length) {
    final idx = raw.indexOf(_forwardGroupMark, searchFrom);
    if (idx < 0) return null;

    final jsonPart = raw.substring(idx + _forwardGroupMark.length).trim();
    if (jsonPart.isEmpty) return null;

    try {
      final decoded = json.decode(jsonPart);
      if (decoded is Map && decoded['fg'] == 1) {
        final items = decoded['items'];
        if (items == null ||
            (items is List &&
                items.every((item) => item is Map<String, dynamic>))) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {
      // Continue looking for another marker below.
    }
    searchFrom = idx + _forwardGroupMark.length;
  }

  return null;
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
  final VoidCallback? onRetryFailed;
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
    this.onRetryFailed,
    this.reactions,
  });

  @override
  Widget build(BuildContext context) {
    final fg = _parseForwardPayload(message.text);
    if (fg == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final items = List<Map<String, dynamic>>.from(fg['items'] ?? const []);
    final caption = (fg['caption'] as String?)?.trim() ?? '';

    final colors = theme.colorScheme;
    final bg = selected
        ? colors.secondaryContainer
        : isMe
            ? colors.primaryContainer
            : colors.surface;
    final textColor = selected
        ? colors.onSecondaryContainer
        : isMe
            ? colors.onPrimaryContainer
            : colors.onSurface;

    return GestureDetector(
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.sizeOf(context).width * .85, 560)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isMe ? 20 : 7),
              bottomRight: Radius.circular(isMe ? 7 : 20),
            ),
            border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Заголовок
              Row(
                children: [
                  Icon(Icons.forward, size: 16, color: textColor),
                  SizedBox(width: 6),
                  Flexible(
                      child: Text(
                    items.length == 1
                        ? 'Пересланное сообщение'
                        : 'Пересланные сообщения',
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  )),
                ],
              ),
              const SizedBox(height: 8),

              // Элементы пересылки
              ...items.map((m) => _ForwardItem(
                    map: m,
                    originalChatId: (fg['from'] ?? '').toString(),
                    idToFile: idToFile,
                    onOpenOriginal: onOpenOriginal,
                    depth: 0,
                  )),

              if (caption.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  caption,
                  style: TextStyle(
                      color: textColor,
                      fontStyle: FontStyle.italic,
                      height: 1.22),
                ),
              ],

              Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  time,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 11,
                  ),
                ),
              ),

              if (message.isFailed) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onRetryFailed,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    child: const Text(
                      'Не отправлено · Повторить',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],

              if (reactions != null && reactions!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: reactions!.entries.map((e) {
                    return GestureDetector(
                      onTap: onReact,
                      child: Container(
                        key: ValueKey('forward-reaction-${e.key}'),
                        constraints:
                            const BoxConstraints(minWidth: 48, minHeight: 48),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                            widthFactor: 1,
                            heightFactor: 1,
                            child: Text('${e.key} ${e.value}',
                                style:
                                    TextStyle(color: textColor, fontSize: 12))),
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
  final String originalChatId;
  final Map<String, ChatFile> idToFile;
  final void Function(String srcMessageId)? onOpenOriginal;
  final int depth;

  const _ForwardItem({
    required this.map,
    required this.originalChatId,
    required this.idToFile,
    this.onOpenOriginal,
    this.depth = 0,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;

    final srcId = (map['id'] ?? '').toString();
    final authorId = (map['aid'] ?? '').toString();
    final author = (map['a'] ?? '').toString();
    final ava = (map['ava'] ?? '').toString();
    final timeStr = (map['t'] ?? '').toString();
    final atIso = (map['at'] ?? '').toString();
    final pretty = atIso.isNotEmpty ? _fmtIsoLocal(atIso) : timeStr;

    final body = (map['x'] ?? '').toString();
    final nestedForward = depth < 3 ? _parseForwardPayload(body) : null;
    final rawF = (map['f'] as List?) ?? const [];
    final fileIds = rawF.whereType<String>().toList();
    final fileObjs =
        rawF.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
      decoration: BoxDecoration(
        border: Border(
            left: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ForwardAuthorLabel(
              originalChatId: originalChatId,
              messageId: srcId,
              authorId: authorId,
              storedName: author,
              builder: (context, resolvedAuthor) => Row(
                    children: [
                      InkWell(
                        onTap: authorId.isNotEmpty
                            ? () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => FriendProfileScreen(
                                          userId: authorId)),
                                )
                            : null,
                        child:
                            ProfileAvatar(name: resolvedAuthor, imageUrl: ava),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          pretty.isEmpty
                              ? resolvedAuthor
                              : '$resolvedAuthor • $pretty',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: textColor),
                        ),
                      ),
                      if (srcId.isNotEmpty && onOpenOriginal != null)
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 48, minHeight: 48),
                          icon: Icon(Icons.open_in_new,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                          tooltip: 'Перейти к исходному',
                          onPressed: () => onOpenOriginal!(srcId),
                        ),
                    ],
                  )),
          if (nestedForward != null) ...[
            const SizedBox(height: 6),
            _NestedForwardPreview(
              payload: nestedForward,
              idToFile: idToFile,
              depth: depth + 1,
            ),
          ] else if (body.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: (srcId.isNotEmpty && onOpenOriginal != null)
                  ? () => onOpenOriginal!(srcId)
                  : null,
              child: Text(
                  body.contains('__FG__:')
                      ? ForwardPayload.displayText(body)
                      : body,
                  style: TextStyle(color: textColor, height: 1.22)),
            ),
          ],
          if (fileIds.isNotEmpty || fileObjs.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ForwardFilesList(
              ids: fileIds,
              idToFile: idToFile,
              fileObjects: fileObjs,
            ),
          ],
        ],
      ),
    );
  }
}

class _NestedForwardPreview extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Map<String, ChatFile> idToFile;
  final int depth;

  const _NestedForwardPreview({
    required this.payload,
    required this.idToFile,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final items = List<Map<String, dynamic>>.from(payload['items'] ?? const []);
    final caption = (payload['caption'] as String?)?.trim() ?? '';

    return Container(
      padding: const EdgeInsets.only(left: 8, top: 4),
      decoration: BoxDecoration(
        border: Border(
            left: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.forward_rounded,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              SizedBox(width: 5),
              Flexible(
                  child: Text(
                'Вложенная пересылка',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              )),
            ],
          ),
          const SizedBox(height: 6),
          ...items.map(
            (m) => _ForwardItem(
              map: m,
              originalChatId: (payload['from'] ?? '').toString(),
              idToFile: idToFile,
              onOpenOriginal: null,
              depth: depth,
            ),
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              caption,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontStyle: FontStyle.italic,
                height: 1.22,
              ),
            ),
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

  const _ForwardFilesList({
    required this.ids,
    required this.idToFile,
    this.fileObjects,
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
              fileId: file.id,
              name: file.fileName,
              type: file.fileType,
              size: file.fileSize,
              url: file.fileUrl,
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
          final fileId = (o['fid'] ?? o['file_id'] ?? o['id'])?.toString();
          final size = int.tryParse((o['size'] ?? '').toString()) ?? 0;
          return _ForwardFileChip(
            fileId: fileId,
            name: name,
            type: type,
            size: size,
            url: url,
          );
        }).toList(),
      );
    }

    return const SizedBox.shrink();
  }
}

class _ForwardFileChip extends StatelessWidget {
  final String? fileId;
  final String name;
  final String type;
  final int size;
  final String url;

  const _ForwardFileChip({
    this.fileId,
    required this.name,
    required this.type,
    required this.size,
    required this.url,
  });

  bool get _isImage {
    final lowerName = name.toLowerCase();
    return type.startsWith('image/') ||
        lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png') ||
        lowerName.endsWith('.gif') ||
        lowerName.endsWith('.webp');
  }

  bool get _isPdf =>
      type.contains('pdf') || name.toLowerCase().endsWith('.pdf');

  void _openPreview(BuildContext context, String displayName) {
    if (url.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _isImage
            ? FullscreenImage(
                imageUrl: url,
                fileName: displayName,
                sourceFileId: fileId,
              )
            : FullscreenFileViewer(
                fileUrl: url,
                fileName: displayName,
                fileSize: size,
                mimeType: type,
                sourceFileId: fileId,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canOpen = url.isNotEmpty;
    final icon = _isImage
        ? Icons.image_outlined
        : _isPdf
            ? Icons.picture_as_pdf_outlined
            : Icons.insert_drive_file_outlined;
    final displayName = name.trim().isEmpty ? 'Вложение' : name.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: canOpen ? () => _openPreview(context, displayName) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
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
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (size > 0) _formatSize(size),
                          if (size <= 0) 'Файл',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
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
                    Icons.visibility_rounded,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
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
