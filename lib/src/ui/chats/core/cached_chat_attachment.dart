import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';

import 'dm_chat_service.dart';

/// A network-free attachment preview for the experimental cached-only chat.
class CachedChatAttachment extends StatefulWidget {
  const CachedChatAttachment({super.key, required this.file, required this.service,
    this.debugBeforeRead, this.debugOpen, this.debugRead});
  final ChatFile file;
  final DmChatService service;
  @visibleForTesting
  final Future<void> Function()? debugBeforeRead;
  @visibleForTesting
  final Future<bool> Function(String path)? debugOpen;
  @visibleForTesting
  final Future<Uint8List?> Function(ChatFile file)? debugRead;

  @override
  State<CachedChatAttachment> createState() => _CachedChatAttachmentState();
}

class _CachedChatAttachmentState extends State<CachedChatAttachment> {
  String? _owner;
  String? _session;
  int _generation = 0;
  int _revision = 0;
  bool _expanded = false;
  late Listenable _changes;
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant CachedChatAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id ||
        oldWidget.file.fileUrl != widget.file.fileUrl ||
        oldWidget.file.isDeleted != widget.file.isDeleted ||
        !identical(oldWidget.service, widget.service)) _bind();
  }

  void _bind() {
    final revision = ++_revision;
    _expanded = false;
    final url = widget.file.fileUrl;
    final file = widget.file;
    _owner = ChatFileAccess.userId;
    _session = ChatFileAccess.currentSessionBinding;
    _generation = ChatFileAccess.generation;
    _changes = Listenable.merge([
      widget.service.cachedAccessChanges!, ChatFileAccess.accessChanges,
    ]);
    bool current() => mounted && revision == _revision &&
        widget.file.fileUrl == url && _allowed();
    final debugRead = widget.debugRead, debugBeforeRead = widget.debugBeforeRead;
    if (debugRead == null && debugBeforeRead == null) {
      _bytes = ChatFileAccess.readCachedOnly(url, permit: current);
    } else {
      _bytes = () async {
        await debugBeforeRead?.call();
        if (!current()) return null;
        final bytes = debugRead == null
            ? await ChatFileAccess.readCachedOnly(url, permit: current)
            : await debugRead(file);
        return current() ? bytes : null;
      }();
    }
  }

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }

  bool _allowed() => !widget.file.isDeleted && widget.service.canReadCached &&
      ChatFileAccess.isViewerCurrent(widget.file.fileUrl, user: _owner,
          epoch: _generation, sessionBinding: _session);

  Future<void> _openDocument(int revision) async {
    bool current() => mounted && revision == _revision && _allowed();
    try {
      if (!current()) return;
      final path = await ChatFileAccess.cachedPathForOpen(widget.file.fileUrl, permit: current);
      if (path == null || !current()) return;
      final debugOpen = widget.debugOpen;
      final bool opened;
      if (debugOpen != null) {
        opened = await debugOpen(path);
      } else {
        final result = await OpenFilex.open(path, type: widget.file.fileType);
        opened = result.type == ResultType.done;
      }
      if (!opened && current()) throw StateError('Не удалось открыть файл');
    } catch (_) {
      if (current()) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть сохранённый файл.')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _changes,
    builder: (context, _) {
      if (!_allowed()) return const SizedBox.shrink();
      return FutureBuilder<Uint8List?>(key: ValueKey(_revision), future: _bytes, builder: (context, snapshot) {
        if (!_allowed()) return const SizedBox.shrink();
        final bytes = snapshot.data;
        if (bytes == null) return Text('Вложение: ${widget.file.fileName}');
        final revision = _revision;
        if (!widget.file.isImage) {
          return TextButton.icon(
            onPressed: () => _openDocument(revision),
            icon: Icon(widget.file.fileIcon), label: Text(widget.file.fileName));
        }
        return GestureDetector(
          onTap: () {
            if (!_allowed() || revision != _revision) return;
            setState(() => _expanded = !_expanded);
          },
          child: ClipRRect(borderRadius: BorderRadius.circular(12),
            child: _expanded
                ? SizedBox(height: MediaQuery.sizeOf(context).height * .65,
                    width: MediaQuery.sizeOf(context).width * .8,
                    child: InteractiveViewer(child: Image.memory(bytes,
                      errorBuilder: (_, __, ___) => Text('Вложение: ${widget.file.fileName}'))))
                : Image.memory(bytes, width: 220, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Text('Вложение: ${widget.file.fileName}'))),
        );
      });
    },
  );
}
