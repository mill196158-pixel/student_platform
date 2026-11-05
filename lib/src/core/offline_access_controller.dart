import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_admission.dart';
import 'transport_failure.dart';

enum AccessDecision { allowed, changePassword, offline, login, stale }

/// One instance per running app. It never persists an offline permission.
class OfflineAccessController extends ChangeNotifier {
  OfflineAccessController({
    required Session? Function() currentSession,
    required Stream<AuthState> authEvents,
    required Future<bool> Function() passwordChangeRequired,
    DateTime Function()? now,
  })  : _currentSession = currentSession,
        _passwordChangeRequired = passwordChangeRequired,
        _now = now ?? DateTime.now {
    final baseline = _currentSession();
    _userId = baseline?.user.id;
    _admission.replaceIdentity(_userId);
    _subscription = authEvents.listen((state) {
      _onAuthState(state);
    }, onError: (Object _, StackTrace __) {
      // Stream errors alone do not grant offline access.
    });
  }

  final Session? Function() _currentSession;
  final Future<bool> Function() _passwordChangeRequired;
  final DateTime Function() _now;
  final _admission = OfflineAdmission();
  late final StreamSubscription<AuthState> _subscription;
  Timer? _expirationTimer;
  DateTime? _ticketExpiry;
  String? _userId;
  int _generation = 0;
  Future<AccessDecision>? _inFlight;
  int? _inFlightGeneration;
  bool _disposed = false;

  int get generation => _generation;

  void _onAuthState(AuthState state) {
    if (_disposed) return;
    final next = state.session?.user.id;
    final identityChanged = next != _userId ||
        state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.signedOut;
    if (identityChanged) {
      _generation++;
      _userId = next;
      _admission.replaceIdentity(next);
      _expirationTimer?.cancel();
      _expirationTimer = null;
      _ticketExpiry = null;
      notifyListeners();
    } else {
      recheckExpiry();
    }
  }

  bool get permitsOffline {
    if (_disposed) return false;
    final session = _currentSession();
    final expiry = _expiry(session);
    return expiry != null &&
        expiry.isAfter(_now()) &&
        session?.user.id == _userId &&
        _admission.permits(_userId, _now());
  }

  /// Called synchronously on app resume before showing any cached data.
  void recheckExpiry() {
    if (!_admission.permits(_userId, _now()) || !permitsOffline) {
      if (_expirationTimer != null) {
        revokeOffline();
      }
    } else if (_ticketExpiry != null) {
      final currentExpiry = _expiry(_currentSession())!;
      final effectiveExpiry = currentExpiry.isBefore(_ticketExpiry!)
          ? currentExpiry
          : _ticketExpiry!;
      _expirationTimer?.cancel();
      _expirationTimer =
          Timer(effectiveExpiry.difference(_now()), recheckExpiry);
    }
  }

  void revokeOffline() {
    _generation++;
    _admission.revoke();
    _expirationTimer?.cancel();
    _expirationTimer = null;
    _ticketExpiry = null;
    if (!_disposed) notifyListeners();
  }

  Future<AccessDecision> checkPolicy() {
    if (_disposed) return Future.value(AccessDecision.stale);
    if (_inFlight != null && _inFlightGeneration == _generation) {
      return _inFlight!;
    }
    final wasOffline = permitsOffline;
    final generation = _generation;
    final future = _checkPolicy(generation);
    _inFlight = future;
    _inFlightGeneration = generation;
    if (wasOffline) notifyListeners();
    future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightGeneration = null;
      }
    });
    return future;
  }

  Future<AccessDecision> _checkPolicy(int generation) async {
    final session = _currentSession();
    final expiry = _expiry(session);
    if (session == null ||
        session.user.id != _userId ||
        expiry == null ||
        !expiry.isAfter(_now())) return AccessDecision.login;
    final attempt = _admission.beginPolicyCheck();
    if (attempt == null) return AccessDecision.login;
    _expirationTimer?.cancel();
    _expirationTimer = null;
    _ticketExpiry = null;
    try {
      final required = await _passwordChangeRequired();
      if (!_sameSession(generation, session.user.id))
        return AccessDecision.stale;
      _admission.revoke();
      return required ? AccessDecision.changePassword : AccessDecision.allowed;
    } catch (error) {
      if (!_sameSession(generation, session.user.id))
        return AccessDecision.stale;
      if (!isTemporaryTransportFailure(error)) return AccessDecision.login;
      // Never extend the initial token's lifetime after a refresh.
      if (!_admission.admitAfterTransportFailure(attempt,
          sessionExpiresAt: expiry, now: _now())) return AccessDecision.login;
      _expirationTimer?.cancel();
      _ticketExpiry = expiry;
      _expirationTimer = Timer(expiry.difference(_now()), recheckExpiry);
      recheckExpiry();
      return AccessDecision.offline;
    }
  }

  bool _sameSession(int generation, String userId) {
    final current = _currentSession();
    final expiry = _expiry(current);
    return !_disposed &&
        generation == _generation &&
        current?.user.id == userId &&
        expiry != null &&
        expiry.isAfter(_now());
  }

  DateTime? _expiry(Session? session) => session?.expiresAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(session!.expiresAt! * 1000);

  @override
  void dispose() {
    _disposed = true;
    _admission.revoke();
    _expirationTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
