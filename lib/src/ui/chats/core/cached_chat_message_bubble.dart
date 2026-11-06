import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_attachment.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/core/scoped_forward_author_resolver.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/message_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

/// Existing message presentation with no online avatar, actions or file fetch.
class CachedChatMessageBubble extends StatelessWidget {
  const CachedChatMessageBubble(
      {super.key,
      required this.message,
      required this.service,
      required this.showAuthor,
      this.authorResolver,
      this.debugForwardAttachmentBuilder});
  final Message message;
  final DmChatService service;
  final bool showAuthor;
  final ScopedForwardAuthorResolver? authorResolver;
  @visibleForTesting
  final Widget Function(ChatFile)? debugForwardAttachmentBuilder;

  @override
  Widget build(BuildContext context) {
    final resolver = authorResolver;
    if (resolver == null) return _buildBody(context, const {});
    return _ScopedForwardNames(message: message, service: service, resolver: resolver,
        builder: (context, names) => _buildBody(context, names));
  }

  Widget _buildBody(BuildContext context,
      Map<(String, String, String), ScopedForwardAuthor> names) {
    String shownAuthor((String, String, String) key, String saved) {
      final verified = names[key];
      if (verified?.isCurrent == true) return verified!.name.trim();
      final value = saved.trim();
      return authorResolver != null && value.isNotEmpty
          ? '$value (автор не подтверждён)' : value;
    }
    final embedded = ForwardPayload.tryParse(message.text);
    final canonical = message.attachments ?? const <ChatFile>[];
    final matched = <ChatFile>[];
    final matchedIds = <String>{};
    var remainingItems = 30;
    var remainingFiles = 30;
    bool addFile(String? id, String url, String name, List<String> lines) {
      final candidates = canonical.where((f) => id != null && id.isNotEmpty && f.id == id).toList();
      final urlMatches = canonical.where((f) => f.fileUrl == url).toList();
      if (candidates.length == 1 && urlMatches.length == 1 &&
          identical(candidates.single, urlMatches.single)) {
        final file = candidates.single;
        if (file.isDeleted) return true;
        if (file.deletionVerified) {
          if (matchedIds.add(file.id)) matched.add(file);
          return true;
        }
      }
      lines.add('📎 ${name.trim().isEmpty ? 'Вложение' : name.trim()}');
      return false;
    }
    void addEmbedded(ForwardPayload payload, List<String> lines, int depth) {
      if (depth > 3) return;
      if ((payload.caption ?? '').trim().isNotEmpty) {
        lines.add(ForwardPayload.displayText(payload.caption!));
      }
      for (final item in payload.items) {
        if (remainingItems-- <= 0) break;
        final nested = depth < 3 ? ForwardPayload.tryParse(item.text) : null;
        if (nested != null) {
          addEmbedded(nested, lines, depth + 1);
        } else {
          final body = ForwardPayload.displayText(item.text);
          final author = shownAuthor((payload.fromChatId, item.messageId, item.authorId), item.authorName);
          if (body.isNotEmpty) lines.add(author.isEmpty ? body : '$author: $body');
          else if (author.isNotEmpty) lines.add(author);
        }
        for (final file in item.files.take(10)) {
          if (remainingFiles-- <= 0) break;
          addFile(file.id, file.url, file.name, lines);
        }
      }
    }
    var text = ChatCardPreview.forPreview(message);
    if (embedded != null) {
      final lines = <String>['Пересланные сообщения'];
      addEmbedded(embedded, lines, 0);
      text = lines.join('\n');
    } else if (message.type == MessageType.forward && message.forward != null) {
      final lines = <String>['Пересланные сообщения'];
      for (final item in message.forward!.items.take(30)) {
        final body = ForwardPayload.displayText(item.text ?? '');
        final author = shownAuthor((message.forward!.fromChatId, item.id, item.authorId), item.authorName);
        if (body.isNotEmpty)
          lines.add(author.isEmpty ? body : '$author: $body');
        else if (author.isNotEmpty) lines.add(author);
        for (final file in item.attachments.take(10)) {
          addFile(file.id, file.url, file.name ?? '', lines);
        }
      }
      text = lines.join('\n');
    }
    // Older structured-forward snapshots did not preserve whether their
    // author label came from the server or a generated fallback. Avoid
    // guessing from the literal name; retain all message and forwarded text.
    final displayAuthor = showAuthor &&
        (message.type != MessageType.forward || message.authorNameVerified == true);
    final bubble = MessageBubble(
        message: message.copyWith(text: text),
        time: DateFormat('HH:mm').format(message.at.toLocal()),
        showAvatar: displayAuthor,
        reserveAvatarSpace: displayAuthor,
        showAuthorLine: displayAuthor,
        localOnlyUserId: service.currentUserId,
        localOnlyAttachmentBuilder: (file) =>
            kDebugMode && debugForwardAttachmentBuilder != null
                ? debugForwardAttachmentBuilder!(file)
                : CachedChatAttachment(file: file, service: service),
        attachments: canonical.where((f) {
          if (f.isDeleted || matchedIds.contains(f.id)) return false;
          if (embedded == null && message.type != MessageType.forward) return true;
          return f.deletionVerified && f.id.isNotEmpty && f.fileUrl.isNotEmpty &&
              canonical.where((x) => x.id == f.id).length == 1 &&
              canonical.where((x) => x.fileUrl == f.fileUrl).length == 1;
        }).toList(),
        reactions: message.reactions,
        receiptTicks: 0);
    if (matched.isEmpty) return bubble;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [bubble, for (final file in matched)
          Padding(padding: const EdgeInsets.only(left: 40, top: 4),
            child: SizedBox(width: 280, child:
              kDebugMode && debugForwardAttachmentBuilder != null
                  ? debugForwardAttachmentBuilder!(file)
                  : CachedChatAttachment(file: file, service: service))) ]);
  }
}

class _ScopedForwardNames extends StatefulWidget {
  const _ScopedForwardNames({required this.message, required this.service,
    required this.resolver, required this.builder});
  final Message message;
  final DmChatService service;
  final ScopedForwardAuthorResolver resolver;
  final Widget Function(BuildContext, Map<(String, String, String), ScopedForwardAuthor>) builder;
  @override State<_ScopedForwardNames> createState() => _ScopedForwardNamesState();
}

class _ScopedForwardNamesState extends State<_ScopedForwardNames> {
  Map<(String, String, String), ScopedForwardAuthor> _names = {};
  int _revision = 0;
  @override void initState() { super.initState(); _resolve(); }
  @override void didUpdateWidget(covariant _ScopedForwardNames oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.message, widget.message) ||
        !identical(oldWidget.service, widget.service) ||
        !identical(oldWidget.resolver.store, widget.resolver.store) ||
        !identical(oldWidget.resolver.capabilities, widget.resolver.capabilities)) {
      _names = {};
      _resolve();
    }
  }

  void _resolve() {
    final revision = ++_revision;
    final targets = <(String, String, String)>{};
    void gather(ForwardPayload payload, int depth) {
      if (depth > 3 || targets.length >= 30) return;
      for (final item in payload.items) {
        if (targets.length >= 30) break;
        targets.add((payload.fromChatId, item.messageId, item.authorId));
        final nested = ForwardPayload.tryParse(item.text);
        if (nested != null) gather(nested, depth + 1);
      }
    }
    final embedded = ForwardPayload.tryParse(widget.message.text);
    if (embedded != null) gather(embedded, 0);
    final structured = widget.message.forward;
    if (structured != null) {
      for (final item in structured.items.take(30 - targets.length)) {
        targets.add((structured.fromChatId, item.id, item.authorId));
      }
    }
    if (targets.isEmpty || !widget.service.canReadCached) return;
    unawaited(() async {
      try {
      final names = <(String, String, String), ScopedForwardAuthor>{};
      for (final target in targets) {
        if (!mounted || revision != _revision || !widget.service.canReadCached) return;
        final value = await widget.resolver.resolve(sourceChatId: target.$1,
            messageId: target.$2, authorId: target.$3);
        if (!mounted || revision != _revision || !widget.service.canReadCached) return;
        if (value != null && value.isCurrent) names[target] = value;
      }
      if (mounted && revision == _revision && widget.service.canReadCached) {
        setState(() => _names = names);
      }
      } catch (_) {
        // A failed optional local lookup leaves the stored label unchanged.
      }
    }());
  }

  @override void dispose() { _revision++; super.dispose(); }
  @override Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.resolver.capabilities,
    builder: (context, _) => widget.service.canReadCached
        ? widget.builder(context, _names)
        : const SizedBox.shrink());
}
