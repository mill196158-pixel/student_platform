import 'dart:async';
import 'dart:io';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Owns the optional pinned-media lease for the current authenticated scope.
/// Initialization is asynchronous: legacy local images never wait for it.
class PinnedMediaRuntime {
  PinnedMediaRuntime({required this.scope, required this.cache,
    required this.currentSession, required this.cacheDirectory});
  final AuthSessionScope scope;
  final ProjectChatServerCache cache;
  final Session? Function() currentSession;
  final Future<Directory> Function() cacheDirectory;
  ProjectMediaProtectionSession? _active;
  Future<void>? _refresh;
  Timer? _retry;
  bool _stopped = false, _again = false;

  void start() {
    scope.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (_stopped) return;
    _again = true;
    if (_refresh != null) return;
    _refresh = _reconcile().whenComplete(() {
      _refresh = null;
      if (_again && !_stopped) _changed();
    });
  }

  Future<void> _reconcile() async {
    _again = false;
    final owner = scope.capture();
    // Explicit logout invalidates scope before cleaning files, while its
    // old session still exists. Keep the lease for that cleanup interval.
    if (owner == null && currentSession() != null) return;
    if (owner != null && _active?.isCurrent == true) return;
    final old = _active;
    if (old != null) {
      if (identical(ChatFileAccess.mediaProtection, old.store)) ChatFileAccess.mediaProtection = null;
      _active = null;
      // Keep the old durable lease until its readers drain, but do not make
      // a new account wait for a stalled native read belonging to the old one.
      unawaited(old.close().catchError((Object _) {}));
    }
    if (_stopped || owner == null || !scope.isCurrent(owner)) return;
    ProjectMediaProtectionSession? next;
    try {
      final root = await cacheDirectory();
      if (_stopped || !scope.isCurrent(owner)) return;
      next = await cache.openMediaProtection(root);
      if (next == null || _stopped || !scope.isCurrent(owner) || !next.isCurrent) {
        if (next != null) unawaited(next.close().catchError((Object _) {}));
        if (next == null && !_stopped && scope.isCurrent(owner)) _scheduleRetry();
        return;
      }
      ChatFileAccess.mediaProtection = next.store;
      _active = next;
      _retry?.cancel(); _retry = null;
    } catch (_) {
      if (next != null) unawaited(next.close().catchError((Object _) {}));
      // An earlier request may still own a fence. Retry without blocking UI.
      if (!_stopped && scope.isCurrent(owner)) {
        _scheduleRetry();
      }
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(milliseconds: 500), _changed);
  }

  Future<void> dispose() async {
    _stopped = true; _retry?.cancel(); scope.removeListener(_changed);
    await _refresh;
    final old = _active; _active = null;
    if (old != null) {
      if (identical(ChatFileAccess.mediaProtection, old.store)) ChatFileAccess.mediaProtection = null;
      await old.close();
    }
  }
}
