import 'dart:async';
import 'auth_session_scope.dart';

/// Opaque session identity, captured before the queued logout begins.
class AuthTransitionOwner {
  AuthTransitionOwner._(this._source, this._scope);
  static AuthTransitionOwner? capture(AuthSessionScope source) {
    final scope = source.capture();
    return scope == null ? null : AuthTransitionOwner._(source, scope);
  }

  final AuthSessionScope _source;
  final AuthOperationScope _scope;
  bool get _isCurrent => _source.isCurrent(_scope);
  @override
  bool operator ==(Object other) =>
      other is AuthTransitionOwner && _scope == other._scope;
  @override
  int get hashCode => _scope.hashCode;
}

/// Serializes app-owned authentication transitions. This does not intercept
/// SDK-owned refreshes or persistence and is not yet wired into production.
class AuthTransitionCoordinator {
  Future<void> _tail = Future<void>.value();
  final _logouts = <AuthTransitionOwner, Future<bool>>{};
  bool _disposed = false;

  /// Callbacks must not await another transition on this coordinator.
  /// Caller timeouts never release a running transition early.
  Future<T> run<T>(Future<T> Function() action) {
    if (_disposed) return Future.error(StateError('Coordinator disposed'));
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_disposed) throw StateError('Coordinator disposed');
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// Repeated requests for the same opaque owner join one logout attempt.
  /// A queued attempt must still be current before it starts destructive work.
  Future<bool> logout(AuthTransitionOwner owner,
      {required Future<void> Function() action}) {
    if (_disposed) return Future.error(StateError('Coordinator disposed'));
    final existing = _logouts[owner];
    if (existing != null) return existing;
    late final Future<bool> result;
    result = run(() async {
      if (!owner._isCurrent) return false;
      await action();
      return true;
    });
    _logouts[owner] = result;
    // Install both handlers immediately; the caller's returned future retains
    // its own success/error result while registry cleanup is always handled.
    unawaited(result.then<void>((_) {
      if (identical(_logouts[owner], result)) _logouts.remove(owner);
    }, onError: (Object _, StackTrace __) {
      if (identical(_logouts[owner], result)) _logouts.remove(owner);
    }));
    return result;
  }

  /// Does not cancel a running callback; queued callbacks will fail closed.
  void dispose() => _disposed = true;
}
