import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../core/auth_session_scope.dart';
import '../../../../core/auth_session_scope_host.dart';
import '../../../chats/data/dm_api.dart';
import '../../models/message.dart';

/// Resolves a legacy generic author only if the current user can still read
/// the exact original message. No profile is fetched by a payload-supplied ID.
typedef ForwardOriginalLoader = Future<Message?> Function(
    {required String chatId, required String messageId});

class ForwardAuthorLabel extends StatefulWidget {
  const ForwardAuthorLabel(
      {super.key,
      required this.originalChatId,
      required this.messageId,
      required this.authorId,
      required this.storedName,
      required this.builder,
      this.debugLoader});
  final String originalChatId;
  final String messageId;
  final String authorId;
  final String storedName;
  final Widget Function(BuildContext, String) builder;
  @visibleForTesting
  final ForwardOriginalLoader? debugLoader;

  @override
  State<ForwardAuthorLabel> createState() => _ForwardAuthorLabelState();
}

class _ForwardAuthorLabelState extends State<ForwardAuthorLabel> {
  static int _active = 0;
  static final _waiting = <Completer<void>>[];
  AuthSessionScope? _scope;
  AuthOperationScope? _owner;
  int _revision = 0;
  String? _resolved;

  static Future<bool> _acquire() {
    if (_active < 4) {
      _active++;
      return Future.value(true);
    }
    if (_waiting.length >= 64) return Future.value(false);
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future.then((_) => true);
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AuthSessionScopeHost.maybeOf(context);
    final owner = scope?.capture();
    if (identical(scope, _scope) && owner == _owner && _revision != 0) return;
    _scope = scope;
    _owner = owner;
    _resolved = null;
    _start();
  }

  @override
  void didUpdateWidget(covariant ForwardAuthorLabel old) {
    super.didUpdateWidget(old);
    if (old.originalChatId != widget.originalChatId ||
        old.messageId != widget.messageId ||
        old.authorId != widget.authorId ||
        old.storedName != widget.storedName) {
      _resolved = null;
      _start();
    }
  }

  void _start() {
    final revision = ++_revision;
    final scope = _scope;
    final chatId = widget.originalChatId.trim();
    final messageId = widget.messageId.trim();
    final authorId = widget.authorId.trim();
    if (widget.storedName.trim().toLowerCase() != 'студент' ||
        scope == null ||
        chatId.isEmpty ||
        messageId.isEmpty ||
        authorId.isEmpty) return;
    bool sameWidget() =>
        mounted &&
        _revision == revision &&
        identical(_scope, scope) &&
        widget.originalChatId.trim() == chatId &&
        widget.messageId.trim() == messageId &&
        widget.authorId.trim() == authorId;
    unawaited(() async {
      try {
        await scope.ready.timeout(const Duration(seconds: 8));
      } catch (_) {
        return;
      }
      if (!sameWidget()) return;
      final owner = scope.capture();
      if (owner == null) return;
      _owner = owner;
      bool current() => sameWidget() && scope.isCurrent(owner);
      if (!await _acquire()) return;
      try {
        if (!current()) return;
        final loader = widget.debugLoader ?? DmApi.loadMessageById;
        final message = await loader(chatId: chatId, messageId: messageId)
            .timeout(const Duration(seconds: 8));
        if (!current() ||
            message == null ||
            message.chatId != chatId ||
            message.id != messageId ||
            message.authorId != authorId) return;
        final name = message.authorName.trim();
        if (name.isEmpty || name.toLowerCase() == 'студент') return;
        setState(() => _resolved = name);
      } catch (_) {
        // Preserve the signed payload label if offline or no longer authorized.
      } finally {
        _release();
      }
    }());
  }

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current =
        _scope != null && _owner != null && _scope!.isCurrent(_owner!);
    return widget.builder(context,
        current ? (_resolved ?? widget.storedName) : widget.storedName);
  }
}
