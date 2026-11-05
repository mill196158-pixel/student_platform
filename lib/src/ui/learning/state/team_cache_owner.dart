import '../../../core/auth_session_scope.dart';

/// A Cubit-lifetime identity. It does not authorize offline reads or writes.
/// Each asynchronous operation must capture a separate, short-lived ticket.
class TeamCacheOwner {
  TeamCacheOwner._(this._scope, this.userId, this.teamId, this._generation);

  static TeamCacheOwner? bind(AuthSessionScope scope, String teamId) {
    if (teamId.trim().isEmpty) return null;
    final owner = scope.capture();
    if (owner == null) return null;
    return TeamCacheOwner._(scope, owner.userId, teamId, scope.generation);
  }

  final AuthSessionScope _scope;
  final String userId;
  final String teamId;
  final int _generation;
  final Object _issuer = Object();
  bool _disposed = false;

  bool belongsTo(AuthSessionScope scope) => identical(_scope, scope);

  TeamCacheTicket? capture() {
    if (_disposed || _scope.generation != _generation) return null;
    final current = _scope.capture();
    if (current == null || current.userId != userId) return null;
    return TeamCacheTicket._(_issuer, teamId, current);
  }

  bool isCurrent(TeamCacheTicket ticket) =>
      !_disposed &&
      identical(ticket._issuer, _issuer) &&
      ticket._teamId == teamId &&
      _scope.generation == _generation &&
      ticket._owner.userId == userId &&
      _scope.isCurrent(ticket._owner);

  void dispose() => _disposed = true;
}

class TeamCacheTicket {
  const TeamCacheTicket._(this._issuer, this._teamId, this._owner);
  final Object _issuer;
  final String _teamId;
  final AuthOperationScope _owner;
}
