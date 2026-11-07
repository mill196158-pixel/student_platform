import 'live_policy_grant_bridge.dart';
import 'offline_policy_grant_host.dart';
import 'transport_failure.dart';
import 'auth_session_scope.dart';
import 'package:flutter/foundation.dart';

class _PolicyRedirectDeadline implements Exception {
  const _PolicyRedirectDeadline();
}

/// The saved grant is recorded here, but is not used to permit offline entry.
Future<String?> guardedPolicyRedirect({
  required String path,
  required bool Function() hasSession,
  required OfflinePolicyGrantAccess? Function() currentAccess,
  void Function(AuthOperationScope)? onAllowed,
  bool Function()? mayAllow,
  Duration policyTimeout = const Duration(seconds: 8),
}) async {
  debugPrint('[startup-route] redirect path: $path');
  if (path == '/login' || path == '/splash' || path == '/guest') return null;
  if (!hasSession()) return '/login';
  if (path == '/change-password') return null;

  for (var attempt = 0; attempt < 2; attempt++) {
    final access = currentAccess();
    final owner = access?.scope.capture();
    if (access == null || owner == null) return '/splash?retry=1';
    bool current() =>
        identical(currentAccess(), access) &&
        hasSession() &&
        access.scope.isCurrent(owner);
    final pending = access.bridge.checkDecision();
    final revision = access.bridge.revision;
    try {
      debugPrint('[startup-route] policy check waiting');
      final decision = await pending.timeout(policyTimeout,
          onTimeout: () => throw const _PolicyRedirectDeadline());
      debugPrint('[startup-route] policy check returned');
      if (!current() || !access.bridge.isCurrentDecision(decision)) continue;
      if (!decision.passwordChangeRequired) {
        // A current policy allow alone is insufficient while an earlier auth
        // operation has not drained or the ordinary transport is suspended.
        if (mayAllow?.call() == false) return '/splash?retry=1';
        onAllowed?.call(owner);
        if (!current() || !access.bridge.isCurrentDecision(decision)) continue;
      }
      return decision.passwordChangeRequired ? '/change-password' : null;
    } on _PolicyRedirectDeadline {
      debugPrint('[startup-route] policy check timed out');
      // Future.timeout does not cancel the server request. Never authorize or
      // automatically loop into offline admission from an unsettled policy.
      if (!current() || revision != access.bridge.revision) continue;
      return '/splash?retry=1';
    } on PolicyCheckStale {
      debugPrint('[startup-route] policy check stale');
      continue;
    } catch (error) {
      debugPrint('[startup-route] policy check error: ${error.runtimeType}');
      if (!current() || revision != access.bridge.revision) continue;
      return isTemporaryTransportFailure(error)
          ? '/splash?retry=1&offline=1'
          : '/login';
    }
  }
  return '/splash?retry=1';
}
