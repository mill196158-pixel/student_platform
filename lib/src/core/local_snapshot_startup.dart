import 'dart:async';

import 'auth_session.dart';
import 'auth_session_scope.dart';
import 'offline_policy_grant.dart';
import 'offline_startup_admission.dart';
import 'session_capabilities.dart';
import 'settled_policy_transport.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Matches the current live scope, not just the SDK session getter: an
/// in-progress sign-out invalidates the scope before the getter is cleared.
bool isSameLocalSnapshotSession(AuthSessionScope scope,
    OfflineSessionBinding expected, Session? session) {
  final owner = scope.capture();
  if (owner == null || !scope.matchesSession(owner, session)) return false;
  final current = scope.bindingFor(owner, expected.issuer);
  return current != null && current.issuer == expected.issuer &&
      current.userId == expected.userId && current.sessionId == expected.sessionId;
}

/// Cold-start local access uses the existing SDK session only to select the
/// account's on-device snapshots. It never accepts an offline password and
/// never grants mutations without a successful live policy check.
class LocalSnapshotStartup {
  LocalSnapshotStartup({
    required this.scope,
    required this.issuer,
    required this.restore,
    required this.checkPolicy,
    this.wait = const Duration(seconds: 3),
    this.onLateDenial,
    this.onCacheOnly,
    this.onOnline,
  });

  final AuthSessionScope scope;
  final String issuer;
  final Future<SessionRestoreStatus> Function() restore;
  final Future<SettledPolicyStatus> Function() checkPolicy;
  final Duration wait;
  final void Function(bool passwordChangeRequired)? onLateDenial;
  final Future<void> Function()? onCacheOnly;
  final Future<void> Function()? onOnline;
  int _revision = 0;

  Future<OfflineStartupResult> resolve(SessionCapabilities caps,
      {bool retriedRotation = false}) async {
    final revision = ++_revision;
    final owner = scope.capture();
    final original = owner == null ? null : scope.bindingFor(owner, issuer);
    if (owner == null || original == null) {
      return OfflineStartupResult.denied;
    }
    bool current() => revision == _revision && scope.isCurrent(owner) &&
        scope.bindingFor(owner, issuer) != null;
    Future<bool> grant(SessionCapabilityMode mode) async {
      if (!current()) return false;
      if (mode == SessionCapabilityMode.cacheOnly) {
        await onCacheOnly?.call();
      } else if (mode == SessionCapabilityMode.online) {
        await onOnline?.call();
      }
      if (!current()) return false;
      final attempt = caps.beginAuthorization(owner);
      if (attempt == null || !current() || !caps.grant(mode, attempt)) return false;
      return current() && caps.mode == mode;
    }
    void denyLate({bool passwordChangeRequired = false}) {
      // A later attempt must not hide a real denial for the same unchanged
      // credentials. A token/account change invalidates the old scope.
      if (!scope.isCurrent(owner) || scope.bindingFor(owner, issuer) == null) return;
      caps.block();
      onLateDenial?.call(passwordChangeRequired);
    }

    try {
      var restoreTimedOut = false;
      final restoreFuture = restore();
      // A delayed server rejection remains observable after the UI deadline.
      unawaited(restoreFuture.then((result) {
        if (restoreTimedOut && result == SessionRestoreStatus.rejected) denyLate();
      }, onError: (Object _, StackTrace __) {}));
      final restored = await restoreFuture.timeout(wait, onTimeout: () {
        restoreTimedOut = true;
        return SessionRestoreStatus.transportFailure;
      });
      if (!current()) {
        if (!retriedRotation && (restored == SessionRestoreStatus.restored ||
            restored == SessionRestoreStatus.stale)) {
          // The SDK may publish the rotated token immediately before its auth
          // event. Retry only for the same server, account and session.
          for (var i = 0; i < 4; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            final nextOwner = scope.capture();
            final next = nextOwner == null ? null : scope.bindingFor(nextOwner, issuer);
            if (next != null && next.issuer == original.issuer &&
                next.userId == original.userId && next.sessionId == original.sessionId) {
              return await resolve(caps, retriedRotation: true);
            }
          }
        }
        return OfflineStartupResult.unavailable;
      }
      if (restored == SessionRestoreStatus.rejected) {
        caps.block();
        return OfflineStartupResult.denied;
      }
      if (restored == SessionRestoreStatus.stale) {
        return OfflineStartupResult.unavailable;
      }
      if (restored == SessionRestoreStatus.transportFailure) {
        return await grant(SessionCapabilityMode.cacheOnly)
            ? OfflineStartupResult.cacheOnly
            : OfflineStartupResult.unavailable;
      }
      var policyTimedOut = false;
      final pending = checkPolicy();
      unawaited(pending.then((result) {
        if (policyTimedOut && (result == SettledPolicyStatus.denied ||
            result == SettledPolicyStatus.passwordChangeRequired)) {
          denyLate(passwordChangeRequired: result == SettledPolicyStatus.passwordChangeRequired);
        }
      }, onError: (Object _, StackTrace __) {}));
      final policy = await pending.timeout(wait, onTimeout: () {
        policyTimedOut = true;
        return SettledPolicyStatus.unavailable;
      });
      if (!current()) return OfflineStartupResult.unavailable;
      switch (policy) {
        case SettledPolicyStatus.allowed:
          return await grant(SessionCapabilityMode.online)
              ? OfflineStartupResult.online
              : OfflineStartupResult.unavailable;
        case SettledPolicyStatus.passwordChangeRequired:
          caps.block();
          return OfflineStartupResult.passwordChangeRequired;
        case SettledPolicyStatus.denied:
          caps.block();
          return OfflineStartupResult.denied;
        case SettledPolicyStatus.unavailable:
          return await grant(SessionCapabilityMode.cacheOnly)
              ? OfflineStartupResult.cacheOnly
              : OfflineStartupResult.unavailable;
        case SettledPolicyStatus.indeterminate:
          return OfflineStartupResult.unavailable;
      }
    } catch (_) {
      return OfflineStartupResult.unavailable;
    }
  }
}
