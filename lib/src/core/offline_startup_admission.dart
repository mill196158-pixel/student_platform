import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session.dart';
import 'auth_session_scope.dart';
import 'coordinated_refresh_client.dart';
import 'offline_policy_grant.dart';
import 'refresh_security_fence.dart';
import 'session_capabilities.dart';
import 'settled_policy_transport.dart';
import 'sqlite_policy_grant_store.dart';
import 'offline_auth_error_receipt.dart';

enum OfflineStartupResult {
  online,
  cacheOnly,
  passwordChangeRequired,
  denied,
  unavailable
}

/// One app-start attempt. The receipt is captured before binding the SDK gate.
/// This controller fences only auth transport; the caller must separately stop
/// push, realtime, auxiliary HTTP and mutations before showing cache-only UI.
class OfflineStartupAdmission {
  OfflineStartupAdmission(
      {required this.client,
      required this.scope,
      required this.store,
      required this.gate,
      required this.monitor,
      required this.fence,
      required this.owner,
      required this.binding,
      required this.prior,
      required this.fenceRevision,
      this.policy,
      this.backend,
      this.publicKey,
      this.policyTimeout = const Duration(seconds: 12)});
  final SupabaseClient client;
  final AuthSessionScope scope;
  final SqlitePolicyGrantStore store;
  final RefreshAdmissionClient gate;
  final RefreshTransportMonitor monitor;
  final RefreshSecurityFence fence;
  final AuthOperationScope owner;
  final OfflineSessionBinding binding;
  final SqlitePriorGrantReceipt? prior;
  final int fenceRevision;
  final SettledPolicyTransport? policy;
  final Uri? backend;
  final String? publicKey;
  final Duration policyTimeout;
  bool _used = false;

  Future<OfflineStartupResult> resolve(SessionCapabilities capabilities) async {
    if (_used || !scope.isCurrent(owner))
      return OfflineStartupResult.unavailable;
    _used = true;
    OfflineAuthErrorReceipt.instance.activateStrict();
    final authSignalBefore = scope.authSignalRevision;
    Object? refreshError;
    try {
      final result = await AuthSession.restoreSessionStatus(client,
          onRefreshError: (error) => refreshError = error);
      if (!scope.isCurrent(owner)) return OfflineStartupResult.denied;
      if (result == SessionRestoreStatus.restored) {
        if (policy == null || backend == null || publicKey == null)
          return OfflineStartupResult.unavailable;
        return await _checkLivePolicy(capabilities);
      }
      if (result != SessionRestoreStatus.transportFailure || prior == null)
        return OfflineStartupResult.denied;
      await gate.suspendAndDrain();
      if (!scope.isCurrent(owner) ||
          !fence.unchangedSince(fenceRevision) ||
          !monitor.eligible) {
        return OfflineStartupResult.unavailable;
      }
      final latest = monitor.latest;
      if (latest == null ||
          !await store.restoreAfterSettledTransportFailure(prior!, latest)) {
        return OfflineStartupResult.unavailable;
      }
      if (!scope.isCurrent(owner) ||
          !fence.unchangedSince(fenceRevision) ||
          !monitor.eligible) {
        return OfflineStartupResult.unavailable;
      }
      return await _issueCachedRead(capabilities, requireRefreshFailures: true,
          refreshError: refreshError, authSignalBefore: authSignalBefore);
    } catch (_) {
      // Unknown storage/transport failure is never an offline permit.
      capabilities.block();
      unawaited(gate.suspendAndDrain());
      return OfflineStartupResult.unavailable;
    }
  }

  Future<OfflineStartupResult> _checkLivePolicy(
      SessionCapabilities caps) async {
    final authority = backend!;
    if (authority.scheme != 'https' ||
        authority.userInfo.isNotEmpty ||
        authority.host.isEmpty ||
        (authority.path.isNotEmpty && authority.path != '/') ||
        authority.hasQuery ||
        authority.hasFragment ||
        '${authority.origin}/auth/v1' != binding.issuer) {
      return OfflineStartupResult.unavailable;
    }
    await gate.suspendAndDrain();
    if (!scope.isCurrent(owner) || !fence.unchangedSince(fenceRevision))
      return OfflineStartupResult.unavailable;
    final session = client.auth.currentSession;
    if (session == null || session.isExpired || session.accessToken.isEmpty)
      return OfflineStartupResult.unavailable;
    final attempt = await store.beginLiveCheck(owner, binding);
    if (attempt == null || !scope.isCurrent(owner))
      return OfflineStartupResult.unavailable;
    final result = await policy!.check(
        backend: backend!,
        userId: owner.userId,
        accessToken: session.accessToken,
        publicKey: publicKey!,
        timeout: policyTimeout);
    if (!scope.isCurrent(owner) || !fence.unchangedSince(fenceRevision))
      return OfflineStartupResult.unavailable;
    switch (result) {
      case SettledPolicyStatus.allowed:
        final now = DateTime.now().toUtc();
        if (client.auth.currentSession?.accessToken != session.accessToken ||
            client.auth.currentSession?.isExpired != false ||
            !await store.saveAllowed(
                attempt,
                OfflinePolicyGrant(
                    issuer: binding.issuer,
                    userId: binding.userId,
                    sessionId: binding.sessionId,
                    checkedAt: now,
                    validUntil: now.add(
                        OfflinePolicyGrant.maximumLocalSnapshotLifetime)))) {
          return OfflineStartupResult.unavailable;
        }
        if (!scope.isCurrent(owner) || !fence.unchangedSince(fenceRevision))
          return OfflineStartupResult.unavailable;
        final authorization = caps.beginAuthorization(owner);
        if (authorization == null || !scope.isCurrent(owner) ||
            !fence.unchangedSince(fenceRevision)) {
          return OfflineStartupResult.unavailable;
        }
        gate.resume();
        if (!caps.grant(SessionCapabilityMode.online, authorization)) {
          unawaited(gate.suspendAndDrain());
          return OfflineStartupResult.unavailable;
        }
        // grant() notifies listeners synchronously; one may invalidate the
        // owner or capability during that notification.
        if (!scope.isCurrent(owner) || !fence.unchangedSince(fenceRevision) ||
            caps.mode != SessionCapabilityMode.online) {
          caps.block();
          unawaited(gate.suspendAndDrain());
          return OfflineStartupResult.unavailable;
        }
        return OfflineStartupResult.online;
      case SettledPolicyStatus.passwordChangeRequired:
      case SettledPolicyStatus.denied:
        if (!await store.revokeAfterLiveCheck(attempt) ||
            !scope.isCurrent(owner)) return OfflineStartupResult.unavailable;
        return result == SettledPolicyStatus.passwordChangeRequired
            ? OfflineStartupResult.passwordChangeRequired
            : OfflineStartupResult.denied;
      case SettledPolicyStatus.unavailable:
        if (prior == null ||
            !await store.restoreAfterSettledTransportFailure(prior!, attempt))
          return OfflineStartupResult.unavailable;
        return _issueCachedRead(caps, requireRefreshFailures: false);
      case SettledPolicyStatus.indeterminate:
        return OfflineStartupResult.unavailable;
    }
  }

  Future<OfflineStartupResult> _issueCachedRead(
      SessionCapabilities capabilities,
      {required bool requireRefreshFailures, Object? refreshError,
      int? authSignalBefore}) async {
    if (!scope.isCurrent(owner) ||
        !fence.unchangedSince(fenceRevision) ||
        (requireRefreshFailures && !monitor.eligible))
      return OfflineStartupResult.unavailable;
    final candidate = await store.readCandidate(owner, binding);
    if (candidate.status != SqliteGrantReadStatus.found ||
        !scope.isCurrent(owner) ||
        !fence.unchangedSince(fenceRevision) ||
        (requireRefreshFailures && !monitor.eligible))
      return OfflineStartupResult.unavailable;
    final attempt = capabilities.beginAuthorization(owner);
    OfflineAuthErrorReceipt.instance.clear();
    if (attempt == null ||
        !capabilities.grant(SessionCapabilityMode.cacheOnly, attempt))
      return OfflineStartupResult.unavailable;
    if (requireRefreshFailures && refreshError != null &&
        authSignalBefore != null &&
        scope.authSignalRevision == authSignalBefore + 1 &&
        identical(scope.lastAuthError, refreshError) &&
        gate.nonRefreshAuthRevision == 0 && gate.suppressedAuthRevision == 0 &&
        gate.activeAuthOperations == 0) {
      final permit = capabilities.capture(SessionCapability.cachedRead);
      final signal = scope.authSignalRevision;
      final gateSignal = gate.authSignals.value;
      if (permit != null) {
        bool valid() => scope.isCurrent(owner) &&
            scope.authSignalRevision == signal &&
            identical(scope.lastAuthError, refreshError) &&
            capabilities.mode == SessionCapabilityMode.cacheOnly &&
            capabilities.permits(permit, SessionCapability.cachedRead) &&
            fence.unchangedSince(fenceRevision) && monitor.eligible &&
            gate.nonRefreshAuthRevision == 0 && gate.suppressedAuthRevision == 0 &&
            gate.activeAuthOperations == 0 && gate.authSignals.value == gateSignal;
        OfflineAuthErrorReceipt.instance.install(refreshError, valid,
            [scope, capabilities, gate.authSignals]);
      }
    }
    return OfflineStartupResult.cacheOnly;
  }
}
