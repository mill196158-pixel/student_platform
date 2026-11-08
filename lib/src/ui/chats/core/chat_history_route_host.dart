import 'dart:async';

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;

import '../../../core/auth_session_scope.dart';
import '../../../core/auth_session_scope_host.dart';
import '../../../core/offline_policy_grant.dart';
import 'project_chat_server_cache.dart';

/// Keeps a history route protected while the ordinary chat subtree is alive.
/// This is an eviction guard, not an authentication or policy decision.
class ChatHistoryRouteHost extends StatefulWidget {
  const ChatHistoryRouteHost({super.key, required this.cache, required this.child,
      this.debugCreateHold});
  final ProjectChatServerCache? cache;
  final Widget child;
  @visibleForTesting
  final HistoryRouteHold Function(ProjectChatServerCache?)? debugCreateHold;

  @override
  State<ChatHistoryRouteHost> createState() => _ChatHistoryRouteHostState();
}

@visibleForTesting
abstract interface class HistoryRouteHold {
  Future<void> get ready;
  Future<void> close();
}

class _RealHold implements HistoryRouteHold {
  _RealHold(ProjectChatServerCache? cache) : _hold = ChatHistoryRouteHold(cache);
  final ChatHistoryRouteHold _hold;
  @override
  Future<void> get ready => _hold.ready;
  @override
  Future<void> close() => _hold.close();
}

class _ChatHistoryRouteHostState extends State<ChatHistoryRouteHost> {
  AuthSessionScope? _scope;
  HistoryRouteHold? _hold;
  (ProjectChatServerCache?, AuthSessionScope?, int, String?, String?)? _cohort;
  bool _ready = false, _blocked = false;
  int _revision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inherited = AuthSessionScopeHost.maybeOf(context);
    final next = widget.cache?.scope ?? inherited;
    if (!identical(_scope, next)) {
      _scope?.removeListener(_onScopeChanged);
      _scope = next;
      _scope?.addListener(_onScopeChanged);
    }
    _synchronize(notify: false);
  }

  @override
  void didUpdateWidget(covariant ChatHistoryRouteHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cache, widget.cache)) {
      final next = widget.cache?.scope ?? AuthSessionScopeHost.maybeRead(context);
      if (!identical(_scope, next)) {
        _scope?.removeListener(_onScopeChanged);
        _scope = next;
        _scope?.addListener(_onScopeChanged);
      }
    }
    _synchronize(notify: false);
  }

  void _onScopeChanged() { if (mounted) _synchronize(notify: true); }

  void _synchronize({required bool notify}) {
    final scope = _scope, cache = widget.cache;
    final generation = scope?.generation ?? 0;
    AuthOperationScope? owner;
    OfflineSessionBinding? binding;
    try {
      owner = scope?.capture();
      binding = cache?.currentBinding();
    } catch (_) {
      // Treat an unavailable identity as unknown, never as another owner.
    }
    final bindingMatchesProject = cache != null && binding != null &&
        binding.issuer == '${cache.project}/auth/v1';
    final valid = owner != null && (cache == null ||
        (identical(cache.scope, scope) && binding != null &&
         bindingMatchesProject && binding.userId == owner.userId && binding.sessionId.isNotEmpty));
    final previous = _cohort;
    if (!valid && previous != null && identical(previous.$1, cache) &&
        identical(previous.$2, scope) && previous.$3 == generation &&
        !(scope?.logoutFenced ?? false) && bindingMatchesProject &&
        binding?.userId == previous.$4 && binding?.sessionId == previous.$5) return;
    // A changed/invalidated owner must not keep the previous chat subtree.
    if (!valid && previous != null && previous.$4 != null) {
      if (!_blocked) {
        _blocked = true;
        _revision++;
        if (notify) setState(() {});
      }
      return;
    }
    final next = (cache, scope, generation, valid ? owner.userId : null,
        valid && binding != null ? binding.sessionId : null);
    if (previous == next && !_blocked) return;
    final old = _hold;
    final hold = (widget.debugCreateHold ?? _RealHold.new)(cache);
    _hold = hold;
    _cohort = next;
    _ready = false;
    _blocked = false;
    final revision = ++_revision;
    if (old != null) unawaited(old.close().catchError((Object _) {}));
    if (notify) setState(() {});
    unawaited(hold.ready.then((_) {
      if (!mounted || revision != _revision || !identical(_hold, hold) || _blocked) return;
      // Identity may change before the corresponding auth event arrives.
      _synchronize(notify: true);
      if (!mounted || revision != _revision || !identical(_hold, hold) || _blocked) return;
      setState(() => _ready = true);
    }, onError: (Object _, StackTrace __) {
      // Actual guard errors keep the route covered rather than expose a race.
    }));
  }

  @override
  void dispose() {
    _scope?.removeListener(_onScopeChanged);
    final hold = _hold;
    _hold = null;
    if (hold != null) unawaited(hold.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready && !_blocked
      ? widget.child
      : const Scaffold(body: Center(child: ProductLoadingIndicator.page()));
}
