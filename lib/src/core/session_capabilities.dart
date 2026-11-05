import 'package:flutter/foundation.dart';

import 'auth_session_scope.dart';

enum SessionCapabilityMode { blocked, online, cacheOnly }

enum SessionCapability { cachedRead, networkRead, mutation, background }

/// Tracks what an already-authorized session may do. This class does not
/// authenticate users or determine whether offline admission is allowed.
class SessionCapabilities extends ChangeNotifier {
  SessionCapabilities(this._session) {
    _session.addListener(_onSessionChanged);
  }

  final AuthSessionScope _session;
  final Object _issuer = Object();
  SessionCapabilityMode _mode = SessionCapabilityMode.blocked;
  AuthOperationScope? _owner;
  int _revision = 0;
  bool _disposed = false;

  SessionCapabilityMode get mode {
    final owner = _owner;
    return _disposed || owner == null || !_session.isCurrent(owner)
        ? SessionCapabilityMode.blocked
        : _mode;
  }

  /// Begin before checking authorization. Starting a new attempt blocks old
  /// permits; a later block or attempt also invalidates this attempt.
  CapabilityAuthorizationAttempt? beginAuthorization(AuthOperationScope owner) {
    if (_disposed || !_session.isCurrent(owner)) return null;
    _mode = SessionCapabilityMode.blocked;
    _owner = null;
    _revision++;
    final attempt = CapabilityAuthorizationAttempt._(_issuer, owner, _revision);
    notifyListeners();
    return attempt;
  }

  /// The caller must establish live policy or offline authorization before
  /// granting a mode. A failed or outdated attempt never grants access.
  bool grant(
      SessionCapabilityMode mode, CapabilityAuthorizationAttempt attempt) {
    if (_disposed ||
        mode == SessionCapabilityMode.blocked ||
        !identical(_issuer, attempt._issuer) ||
        attempt._revision != _revision ||
        !_session.isCurrent(attempt._owner)) return false;
    _mode = mode;
    _owner = attempt._owner;
    _revision++;
    notifyListeners();
    return true;
  }

  void block() {
    if (_disposed) return;
    _mode = SessionCapabilityMode.blocked;
    _owner = null;
    _revision++;
    notifyListeners();
  }

  CapabilityPermit? capture(SessionCapability capability) {
    final owner = _owner;
    if (_disposed ||
        owner == null ||
        !_session.isCurrent(owner) ||
        !_allowed(_mode, capability)) return null;
    return CapabilityPermit._(_issuer, owner, capability, _revision);
  }

  bool permits(CapabilityPermit permit, SessionCapability requiredCapability) =>
      !_disposed &&
      identical(_issuer, permit._issuer) &&
      permit._revision == _revision &&
      permit.capability == requiredCapability &&
      _owner == permit._owner &&
      _session.isCurrent(permit._owner) &&
      _allowed(_mode, permit.capability);

  void _onSessionChanged() {
    final owner = _owner;
    if (owner != null && !_session.isCurrent(owner)) block();
  }

  static bool _allowed(
      SessionCapabilityMode mode, SessionCapability capability) {
    if (mode == SessionCapabilityMode.blocked) return false;
    if (mode == SessionCapabilityMode.cacheOnly) {
      return capability == SessionCapability.cachedRead;
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _owner = null;
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }
}

class CapabilityAuthorizationAttempt {
  const CapabilityAuthorizationAttempt._(
      this._issuer, this._owner, this._revision);
  final Object _issuer;
  final AuthOperationScope _owner;
  final int _revision;
}

class CapabilityPermit {
  const CapabilityPermit._(
      this._issuer, this._owner, this.capability, this._revision);
  final Object _issuer;
  final AuthOperationScope _owner;
  final int _revision;
  final SessionCapability capability;
}
