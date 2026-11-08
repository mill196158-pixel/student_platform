import 'dart:async';

import 'optional_image_cache_budget.dart';
import 'session_capabilities.dart';
import '../ui/chats/core/project_chat_server_cache.dart';

/// A single non-blocking maintenance pass for recoverable server snapshots.
/// It reports logical history removed, never physical disk space reclaimed.
class OrdinaryHistoryMaintenance {
  OrdinaryHistoryMaintenance({required this.cache, required this.capabilities,
    required this.budget, required this.probeOnline, required this.isCurrent});
  final ProjectChatServerCache cache;
  final SessionCapabilities capabilities;
  final OptionalImageCacheBudget budget;
  final Future<bool> Function() probeOnline;
  final bool Function() isCurrent;
  Future<int?>? _running;

  Future<int?> run() {
    final running = _running;
    if (running != null) return running;
    final next = _run();
    _running = next;
    unawaited(next.then<void>((_) {
      if (identical(_running, next)) _running = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_running, next)) _running = null;
    }));
    return next;
  }

  Future<int?> _run() async {
    try {
    final scope = cache.scope;
    final owner = scope.capture();
    final dbOwner = captureProjectDatabaseOwner(cache.db);
    final permit = capabilities.capture(SessionCapability.networkRead);
    final binding = cache.currentBinding();
    if (!isCurrent() || owner == null || dbOwner == null || permit == null || binding == null ||
        binding.userId != owner.userId || binding.issuer != '${cache.project}/auth/v1' ||
        !capabilities.ownsFor(permit, owner, SessionCapability.networkRead)) return null;
    bool ownerCurrent() {
      try {
        final now = cache.currentBinding();
        return isCurrent() && scope.isCurrent(owner) && dbOwner.isCurrentFor(cache.db) &&
            capabilities.mode == SessionCapabilityMode.online &&
            capabilities.ownsFor(permit, owner, SessionCapability.networkRead) &&
            now != null && now.issuer == binding.issuer && now.userId == binding.userId &&
            now.sessionId == binding.sessionId;
      } catch (_) { return false; }
    }
      if (!await probeOnline().timeout(const Duration(seconds: 3), onTimeout: () => false) ||
          !ownerCurrent()) return null;
      final freshness = Stopwatch()..start();
      await budget.refreshForDisplay().timeout(const Duration(seconds: 3));
      final observation = budget.captureFreshObservation();
      if (observation == null || !ownerCurrent()) return null;
      bool current() => freshness.elapsed < const Duration(seconds: 10) && ownerCurrent() &&
          budget.isObservationCurrent(observation);
      if (!current()) return null;
      final cost = observation.observedBytes + observation.reservedBytes + observation.serviceReserveBytes;
      final guard = await cache.beginOrdinaryBudgetMaintenance(dbOwner,
          knownOptionalCost: cost, budgetLimit: observation.limitBytes,
          observationAndOnlineCurrent: current);
      if (guard == null) return null;
      try {
        return guard.logicalBytesEvicted;
      } finally {
        await cache.releaseHistoryAppGuard(guard);
        if (guard.logicalBytesEvicted > 0) budget.refreshAfterCollection();
      }
    } catch (_) { return null; }
  }
}
