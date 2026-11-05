import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope.dart';
import 'offline_policy_grant.dart';
import 'offline_policy_grant_store.dart';

class PolicyCheckStale implements Exception {
  const PolicyCheckStale();
}

class LivePolicyDecision {
  const LivePolicyDecision._(
      this.passwordChangeRequired, this._revision, this._issuer);
  final bool passwordChangeRequired;
  final int _revision;
  final Object _issuer;
}

/// Records a live policy result; this does not grant offline access. The host
/// must retain one bridge per scope, and the router must recheck both scope
/// and bridge identity after awaiting a decision.
class LivePolicyGrantBridge {
  LivePolicyGrantBridge(
      {required this.scope,
      required this.store,
      required this.currentBinding,
      required this.readLivePolicy,
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AuthSessionScope scope;
  final OfflinePolicyGrantStore store;
  final OfflineSessionBinding? Function() currentBinding;
  final Future<bool> Function() readLivePolicy;
  final DateTime Function() _clock;
  int _revision = 0;
  final Object _issuer = Object();
  int get revision => _revision;

  Future<bool> check() async => (await checkDecision()).passwordChangeRequired;

  bool isCurrentDecision(LivePolicyDecision decision) =>
      identical(decision._issuer, _issuer) && decision._revision == _revision;

  Future<LivePolicyDecision> checkDecision() async {
    final owner = scope.capture();
    if (owner == null) throw const PolicyCheckStale();
    final revision = ++_revision;
    OfflineSessionBinding? binding;
    OfflineGrantAttempt? attempt;
    try {
      binding = currentBinding();
      attempt = binding == null ? null : store.beginLiveCheck(owner, binding);
    } catch (_) {
      // Failure to prepare optional storage must not break online policy.
    }
    bool current() => revision == _revision && scope.isCurrent(owner);
    try {
      final required = await readLivePolicy();
      if (!current()) throw const PolicyCheckStale();
      if (attempt != null && binding != null) {
        if (required) {
          _ignoreStorage(() => store.revokeAfterLiveCheck(attempt!));
        } else {
          final now = _clock().toUtc();
          final grant = OfflinePolicyGrant(
              issuer: binding.issuer,
              userId: binding.userId,
              sessionId: binding.sessionId,
              checkedAt: now,
              validUntil: now.add(OfflinePolicyGrant.maximumLifetime));
          _ignoreStorage(() => store.saveAfterLiveCheck(attempt!, grant));
        }
      }
      return LivePolicyDecision._(required, revision, _issuer);
    } catch (error) {
      if (!current()) throw const PolicyCheckStale();
      if (attempt != null && _isConfirmedDenial(error)) {
        _ignoreStorage(() => store.revokeAfterLiveCheck(attempt!));
      }
      rethrow;
    }
  }

  void _ignoreStorage(Future<bool> Function() operation) {
    // Attach a handler immediately. Policy navigation does not wait for disk.
    try {
      unawaited(operation()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    } catch (_) {}
  }

  static bool _isConfirmedDenial(Object error) {
    if (error is AuthException)
      return error.statusCode == '401' || error.statusCode == '403';
    if (error is PostgrestException) {
      return const {
        '401',
        '403',
        '42501',
        'PGRST301',
        'PGRST302',
        'PGRST303',
        'PT401',
        'PT403'
      }.contains(error.code);
    }
    return false;
  }
}
