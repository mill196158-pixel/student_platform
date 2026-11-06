import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope.dart';
import 'coordinated_refresh_client.dart';
import 'offline_policy_grant.dart';
import 'refresh_security_fence.dart';
import 'session_capabilities.dart';
import 'settled_policy_transport.dart';
import 'sqlite_policy_grant_store.dart';

/// QA-only process-lifetime observer. It never grants UI access: it only
/// refreshes a durable offline grant after an independently verified policy.
class RefreshPolicyGrantObserver {
  RefreshPolicyGrantObserver(
      {required this.client,
      required this.scope,
      required this.store,
      required this.gate,
      required this.fence,
      required this.policy,
      required this.backend,
      required this.publicKey,
      this.closePreviousOnline})
      : _clientTrusted = (() =>
            identical(client, SupabaseConfig.client) &&
            backend.origin == Uri.parse(SupabaseConfig.url).origin) {
    _listen();
  }
  @visibleForTesting
  RefreshPolicyGrantObserver.forTesting(
      {required this.client,
      required this.scope,
      required this.store,
      required this.gate,
      required this.fence,
      required this.policy,
      required this.backend,
      required this.publicKey,
      this.closePreviousOnline})
      : _clientTrusted = (() => true) {
    _listen();
  }
  final SupabaseClient client;
  final AuthSessionScope scope;
  final SqlitePolicyGrantStore store;
  final RefreshAdmissionClient gate;
  final RefreshSecurityFence fence;
  final SettledPolicyTransport policy;
  final Uri backend;
  final String publicKey;
  /// QA only: close and drain the previous online UI before issuing a permit.
  final Future<bool> Function()? closePreviousOnline;
  final bool Function() _clientTrusted;
  late final StreamSubscription<AuthState> _subscription;
  OfflineSessionBinding? _armed;
  AuthOperationScope? _armedOwner;
  CapabilityPermit? _onlinePermit;
  SessionCapabilities? _capabilities;
  int _armedCapsRevision = 0;
  bool _handlingRefresh = false;
  int _revision = 0;
  bool _disposed = false;
  final Set<Future<void>> _pending = {};

  void _listen() {
    _subscription = client.auth.onAuthStateChange
        .listen(_event, onError: (Object _, StackTrace __) => disarm());
  }

  bool _sameSession(OfflineSessionBinding a, OfflineSessionBinding b) =>
      a.issuer == b.issuer &&
      a.userId == b.userId &&
      a.sessionId == b.sessionId;
  bool arm(AuthOperationScope owner, OfflineSessionBinding binding,
      SessionCapabilities caps) {
    if (_disposed ||
        !_clientTrusted() ||
        backend.scheme != 'https' ||
        backend.userInfo.isNotEmpty ||
        '${backend.origin}/auth/v1' != binding.issuer ||
        !scope.isCurrent(owner) ||
        !scope.matchesSession(owner, client.auth.currentSession) ||
        caps.mode != SessionCapabilityMode.online) return false;
    final actual = scope.bindingFor(owner, binding.issuer);
    if (actual == null || !_sameSession(actual, binding)) return false;
    final onlinePermit = caps.capture(SessionCapability.networkRead);
    if (onlinePermit == null ||
        !caps.permits(onlinePermit, SessionCapability.networkRead))
      return false;
    _revision++;
    _capabilities?.removeListener(_capsChanged);
    _armed = binding;
    _armedOwner = owner;
    _onlinePermit = onlinePermit;
    _capabilities = caps;
    _armedCapsRevision = caps.revision;
    _handlingRefresh = false;
    caps.addListener(_capsChanged);
    return true;
  }

  void disarm() {
    _revision++;
    _capabilities?.removeListener(_capsChanged);
    _armed = null;
    _armedOwner = null;
    _onlinePermit = null;
    _capabilities = null;
    _handlingRefresh = false;
  }

  void _capsChanged() {
    final caps = _capabilities, owner = _armedOwner;
    if (caps == null || owner == null) return;
    // The single expected invalidation is caused by the SDK changing this
    // owner's credentials. Every explicit block or later change cancels work.
    if (!_handlingRefresh &&
        caps.lastBlockReason == CapabilityBlockReason.ownerChanged &&
        caps.revision == _armedCapsRevision + 1 &&
        !scope.isCurrent(owner)) return;
    disarm();
  }

  void _event(AuthState event) {
    if (_disposed || _armed == null) return;
    if (event.event == AuthChangeEvent.signedOut ||
        event.event == AuthChangeEvent.signedIn ||
        event.event == AuthChangeEvent.passwordRecovery) {
      disarm();
      return;
    }
    if (event.event != AuthChangeEvent.tokenRefreshed || event.session == null)
      return;
    final caps = _capabilities;
    final originalOwner = _armedOwner, permit = _onlinePermit;
    final unchanged = caps != null &&
        originalOwner != null &&
        permit != null &&
        scope.isCurrent(originalOwner) &&
        scope.matchesSession(originalOwner, event.session) &&
        caps.mode == SessionCapabilityMode.online &&
        caps.revision == _armedCapsRevision &&
        caps.permits(permit, SessionCapability.networkRead);
    final rotated = caps != null &&
        caps.mode == SessionCapabilityMode.blocked &&
        caps.lastBlockReason == CapabilityBlockReason.ownerChanged &&
        caps.revision == _armedCapsRevision + 1;
    if (_handlingRefresh || caps == null || (!unchanged && !rotated)) {
      disarm();
      return;
    }
    _handlingRefresh = true;
    final capsRevision = caps.revision;
    final revision = ++_revision;
    final expected = event.session!;
    late Future<void> task;
    task = Future<void>.microtask(
            () => _refresh(expected, revision, capsRevision, unchanged))
        .catchError((Object _) {})
        .whenComplete(() => _pending.remove(task));
    _pending.add(task);
  }

  Future<void> _refresh(
      Session expected, int revision, int capsRevision, bool unchanged) async {
    final arm = _armed, caps = _capabilities;
    if (arm == null ||
        caps == null ||
        _disposed ||
        revision != _revision ||
        !_clientTrusted()) return;
    final owner = scope.capture();
    if (owner == null ||
        !scope.matchesSession(owner, expected) ||
        !scope.matchesSession(owner, client.auth.currentSession)) return;
    final binding = scope.bindingFor(owner, arm.issuer);
    if (binding == null || !_sameSession(arm, binding)) {
      disarm();
      return;
    }
    final fenceRevision = fence.revision;
    bool current() =>
        !_disposed &&
        revision == _revision &&
        identical(caps, _capabilities) &&
        caps.revision == capsRevision &&
        (unchanged
            ? caps.mode == SessionCapabilityMode.online &&
                _onlinePermit != null &&
                caps.permits(_onlinePermit!, SessionCapability.networkRead)
            : caps.mode == SessionCapabilityMode.blocked &&
                caps.lastBlockReason == CapabilityBlockReason.ownerChanged) &&
        _armed != null &&
        _sameSession(_armed!, binding) &&
        _clientTrusted() &&
        scope.isCurrent(owner) &&
        scope.matchesSession(owner, client.auth.currentSession) &&
        fence.unchangedSince(fenceRevision);
    var keepArmed = false;
    var reauthorize = false;
    await gate.runTrackedPolicy(() async {
      if (!current()) return;
      final attempt = await store.beginLiveCheck(owner, binding);
      if (attempt == null || !current()) return;
      final session = client.auth.currentSession;
      if (session == null || session.isExpired || !current()) return;
      final result = await policy.check(
          backend: backend,
          userId: binding.userId,
          accessToken: session.accessToken,
          publicKey: publicKey,
          timeout: const Duration(seconds: 12));
      if (!current()) return;
      if (result == SettledPolicyStatus.allowed) {
        final now = DateTime.now().toUtc();
        final saved = await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: binding.issuer,
                userId: binding.userId,
                sessionId: binding.sessionId,
                checkedAt: now,
                validUntil:
                    now.add(OfflinePolicyGrant.maximumLocalSnapshotLifetime)),
            stillCurrent: current);
        keepArmed = saved && unchanged && current();
        reauthorize = saved && !unchanged && current();
      } else if (result == SettledPolicyStatus.denied ||
          result == SettledPolicyStatus.passwordChangeRequired) {
        final revoked = await store.revokeAfterLiveCheck(attempt);
        if (revoked && current()) caps.block();
      }
    });
    if (reauthorize && current() && closePreviousOnline != null) {
      var drained = false;
      try {
        drained = await closePreviousOnline!();
      } catch (_) {
        // A failed or indeterminate drain cannot authorize a new UI.
      }
      if (drained && current()) {
        // beginAuthorization and grant synchronously notify arbitrary
        // listeners. Explicit blocks or session changes at either point win.
        caps.removeListener(_capsChanged);
        bool identityCurrent() =>
            !_disposed && revision == _revision &&
            identical(caps, _capabilities) &&
            _armed != null && _sameSession(_armed!, binding) &&
            _clientTrusted() && scope.isCurrent(owner) &&
            scope.matchesSession(owner, client.auth.currentSession) &&
            fence.unchangedSince(fenceRevision);
        final attempt = caps.beginAuthorization(owner);
        if (attempt != null && identityCurrent() &&
            caps.revision == capsRevision + 1 &&
            caps.mode == SessionCapabilityMode.blocked &&
            caps.grant(SessionCapabilityMode.online, attempt) &&
            identityCurrent() && caps.revision == capsRevision + 2 &&
            caps.mode == SessionCapabilityMode.online &&
            this.arm(owner, binding, caps)) return;
        if (identityCurrent() && caps.revision == capsRevision + 2 &&
            caps.mode == SessionCapabilityMode.online) caps.block();
      }
    }
    if (revision == _revision) {
      if (keepArmed && current()) {
        _handlingRefresh = false;
        _armedOwner = owner;
        _armedCapsRevision = caps.revision;
      } else {
        disarm();
      }
    }
  }

  @visibleForTesting
  Future<void> settled() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    disarm();
    await _subscription.cancel();
    await settled();
  }
}
