/// In-memory admission to a read-only cache viewer for one authenticated
/// session. This never authorizes network operations or persists a ticket.
class OfflineAdmission {
  final Object _issuer = Object();
  String? _userId;
  int _authEpoch = 0;
  _OfflineTicket? _ticket;

  /// Call for sign-in/sign-out, including a new session for the same user.
  void replaceIdentity(String? userId) {
    _authEpoch++;
    _userId = _normalized(userId);
    _ticket = null;
  }

  /// Capture before the live policy request so a late response cannot grant
  /// access to a newer session, even when it belongs to the same user.
  OfflinePolicyAttempt? beginPolicyCheck() {
    final id = _userId;
    if (id == null) return null;
    // A later policy check supersedes any older in-flight check.
    _authEpoch++;
    _ticket = null;
    return OfflinePolicyAttempt._(_issuer, id, _authEpoch);
  }

  /// Use only when the live policy check failed due to a transport error.
  bool admitAfterTransportFailure(
    OfflinePolicyAttempt attempt, {
    required DateTime? sessionExpiresAt,
    required DateTime now,
  }) {
    if (!_matches(attempt) ||
        sessionExpiresAt == null ||
        !sessionExpiresAt.isAfter(now)) {
      return false;
    }
    _ticket = _OfflineTicket(attempt, sessionExpiresAt);
    return true;
  }

  bool permits(String? userId, DateTime now) {
    final ticket = _ticket;
    return ticket != null &&
        _normalized(userId) == ticket.attempt.userId &&
        _matches(ticket.attempt) &&
        ticket.expiresAt.isAfter(now);
  }

  /// A definitive policy result, explicit logout, or a new session must
  /// revoke admission; reconnecting alone does not authorize mutations.
  void revoke() {
    _authEpoch++;
    _ticket = null;
  }

  bool _matches(OfflinePolicyAttempt attempt) =>
      identical(_issuer, attempt._issuer) &&
      _userId == attempt.userId &&
      _authEpoch == attempt._epoch;

  static String? _normalized(String? userId) {
    final result = (userId ?? '').trim();
    return result.isEmpty ? null : result;
  }
}

class OfflinePolicyAttempt {
  const OfflinePolicyAttempt._(this._issuer, this.userId, this._epoch);

  final Object _issuer;
  final String userId;
  final int _epoch;
}

class _OfflineTicket {
  const _OfflineTicket(this.attempt, this.expiresAt);

  final OfflinePolicyAttempt attempt;
  final DateTime expiresAt;
}
