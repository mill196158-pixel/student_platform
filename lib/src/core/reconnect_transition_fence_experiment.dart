import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_session_scope.dart';

/// Disconnected experiment: it does not authorize or restore navigation.
/// Unknown SDK or engine ownership never yields a ticket.
class ReconnectTransitionFenceExperiment {
  ReconnectTransitionFenceExperiment({required AuthSessionScope scope,
    required ValueListenable<int> authSignals})
      : this._(scope, authSignals, false, () => false);

  /// A synthetic managed perimeter. This is not a production receipt.
  @visibleForTesting
  ReconnectTransitionFenceExperiment.syntheticManaged({required AuthSessionScope scope,
    required ValueListenable<int> authSignals, required bool Function() isQuiescent})
      : this._(scope, authSignals, true, isQuiescent);

  ReconnectTransitionFenceExperiment._(this._scope, this._signals, this._syntheticManaged, this._isQuiescent) {
    _scope.addListener(_invalidate);
    _signals.addListener(_invalidate);
  }

  final AuthSessionScope _scope;
  final ValueListenable<int> _signals;
  final bool _syntheticManaged;
  final bool Function() _isQuiescent;
  int _epoch = 0;
  bool _disposed = false;
  bool _ambiguous = false;
  int _activeTransitions = 0;

  void _invalidate() {
    _epoch++;
    _ambiguous = true;
  }

  bool get _quiet {
    try {
      if (_isQuiescent()) return true;
    } catch (_) {}
    _invalidate();
    return false;
  }

  ReconnectFenceTicket? capture() {
    if (_disposed || _ambiguous || !_syntheticManaged || _activeTransitions != 0 || !_quiet) return null;
    final owner = _scope.capture();
    if (owner == null || !_scope.isCurrent(owner)) return null;
    return ReconnectFenceTicket._(this, owner, _epoch, _signals.value);
  }

  bool permits(ReconnectFenceTicket ticket) =>
      !_disposed && !_ambiguous && _syntheticManaged && _activeTransitions == 0 && _quiet &&
      identical(ticket._issuer, this) && ticket._epoch == _epoch &&
      ticket._signal == _signals.value && _scope.isCurrent(ticket._owner);

  /// Invalidates synchronously before [operation] starts, including if it
  /// throws. Callers must not treat completion as a session receipt.
  Future<T> runAppOwnedTransition<T>(Future<T> Function() operation) {
    if (_disposed) return Future.error(StateError('Fence disposed'));
    _activeTransitions++;
    _invalidate();
    return Future<T>.sync(operation).whenComplete(() {
      _activeTransitions--;
      _invalidate();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidate();
    _scope.removeListener(_invalidate);
    _signals.removeListener(_invalidate);
  }
}

class ReconnectFenceTicket {
  ReconnectFenceTicket._(this._issuer, this._owner, this._epoch, this._signal);
  final ReconnectTransitionFenceExperiment _issuer;
  final AuthOperationScope _owner;
  final int _epoch;
  final int _signal;
}
