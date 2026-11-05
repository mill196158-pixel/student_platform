import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// App-lifetime guard for work started under a particular authenticated
/// session. Scope values contain credentials and must never be logged.
class AuthSessionScope extends ChangeNotifier {
  AuthSessionScope({
    required Session? Function() currentSession,
    required Stream<AuthState> authEvents,
  }) : _currentSession = currentSession {
    // A retained session is an owner identity only, never authorization.
    _observed = _identity(_currentSession());
    _subscription =
        authEvents.listen(_onEvent, onError: (Object _, StackTrace __) {
      if (!_ready.isCompleted) _ready.complete();
    }, onDone: () {
      _closed = true;
      _generation++;
      if (!_ready.isCompleted) _ready.complete();
      if (!_disposed) notifyListeners();
    });
  }

  final Session? Function() _currentSession;
  final Object _issuer = Object();
  final Completer<void> _ready = Completer<void>();
  late final StreamSubscription<AuthState> _subscription;
  (String, String, String?)? _observed;
  int _generation = 0;
  bool _invalidated = false;
  bool _logoutAcknowledged = false;
  bool _disposed = false;
  bool _closed = false;

  Future<void> get ready => _ready.future;
  int get generation => _generation;

  void _onEvent(AuthState event) {
    if (_disposed) return;
    final next = _identity(event.session);
    final materialChanged = next != _observed;
    final changed = next?.$1 != _observed?.$1 ||
        event.event == AuthChangeEvent.signedIn ||
        event.event == AuthChangeEvent.signedOut ||
        event.event == AuthChangeEvent.passwordRecovery;
    if (changed) _generation++;
    _observed = next;
    if (_invalidated && event.event == AuthChangeEvent.signedOut) {
      _logoutAcknowledged = true;
    } else if (_invalidated &&
        _logoutAcknowledged &&
        (event.event == AuthChangeEvent.signedIn ||
            event.event == AuthChangeEvent.passwordRecovery)) {
      _invalidated = false;
      _logoutAcknowledged = false;
    }
    if (!_ready.isCompleted) _ready.complete();
    if (changed || materialChanged) notifyListeners();
  }

  /// Call synchronously when explicit logout starts, before any awaits.
  void invalidateForSignOut() {
    if (_disposed) return;
    _invalidated = true;
    _logoutAcknowledged = false;
    _generation++;
    notifyListeners();
  }

  AuthOperationScope? capture() {
    if (_disposed || _closed || !_ready.isCompleted || _invalidated)
      return null;
    final identity = _identity(_currentSession());
    if (identity == null || identity != _observed) return null;
    return AuthOperationScope._(_issuer, identity, _generation);
  }

  bool isCurrent(AuthOperationScope scope) =>
      !_disposed &&
      !_closed &&
      !_invalidated &&
      identical(scope._issuer, _issuer) &&
      scope._generation == _generation &&
      scope._identity == _observed &&
      scope._identity == _identity(_currentSession());

  static (String, String, String?)? _identity(Session? session) {
    if (session == null ||
        session.user.id.trim().isEmpty ||
        session.accessToken.isEmpty) {
      return null;
    }
    return (session.user.id, session.accessToken, session.refreshToken);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    if (!_ready.isCompleted) _ready.complete();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

class AuthOperationScope {
  const AuthOperationScope._(this._issuer, this._identity, this._generation);
  final Object _issuer;
  final (String, String, String?) _identity;
  final int _generation;
  String get userId => _identity.$1;

  @override
  bool operator ==(Object other) =>
      other is AuthOperationScope &&
      identical(_issuer, other._issuer) &&
      _generation == other._generation &&
      _identity == other._identity;

  @override
  int get hashCode => Object.hash(_issuer, _generation, _identity);
}
