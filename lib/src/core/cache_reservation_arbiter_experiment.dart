import 'cache_budget_policy_experiment.dart';

/// A disconnected, process-local temporary-cache experiment; protected bytes
/// are excluded, so total disk usage can exceed this budget.
/// No store is connected, and an unverifiable collector must never use it.
class CacheReservationSnapshot {
  const CacheReservationSnapshot({required this.components,
      required this.complete, required this.isCurrent});
  final List<CacheFootprintObservation> components;
  final bool complete;
  /// Must attest to the physical measurement and exact owner through use.
  final bool Function() isCurrent;
}

typedef CacheReservationMeasure = Future<CacheReservationSnapshot?> Function();

class CacheReservationArbiterExperiment {
  CacheReservationArbiterExperiment({this.temporaryBudgetBytes = CacheBudgetPolicyExperiment.defaultBudgetBytes});
  final int temporaryBudgetBytes;
  final Map<Object, int> _reserved = {};
  int _revision = 0;

  int get reservedBytes => _reserved.values.fold(0, (sum, value) => sum + value);

  bool _valid(bool Function() check) {
    try { return check(); } catch (_) { return false; }
  }

  /// [peakAdditionalBytes] must include the maximum simultaneous temporary
  /// and destination bytes; it is not merely the final net increase.
  Future<CacheReservationExperiment?> reserve({required int peakAdditionalBytes,
      required bool Function() ownerIsCurrent, required CacheReservationMeasure measure}) async {
    if (peakAdditionalBytes <= 0 || temporaryBudgetBytes < 0 ||
        peakAdditionalBytes > temporaryBudgetBytes || !_valid(ownerIsCurrent)) return null;
    final revision = _revision;
    CacheReservationSnapshot? snapshot;
    try { snapshot = await measure(); } catch (_) { return null; }
    if (snapshot == null || revision != _revision || !_valid(ownerIsCurrent) ||
        !_valid(snapshot.isCurrent)) return null;
    final estimate = CacheBudgetPolicyExperiment.estimate(snapshot.components,
        budgetBytes: temporaryBudgetBytes, complete: snapshot.complete);
    if (estimate == null || !estimate.budgetClassificationComplete ||
        estimate.temporaryBytes > temporaryBudgetBytes) return null;
    final occupied = estimate.temporaryBytes;
    final reserved = reservedBytes;
    if (reserved > temporaryBudgetBytes - occupied ||
        peakAdditionalBytes > temporaryBudgetBytes - occupied - reserved ||
        revision != _revision || !_valid(ownerIsCurrent) || !_valid(snapshot.isCurrent)) return null;
    final id = Object();
    _reserved[id] = peakAdditionalBytes;
    _revision++;
    return CacheReservationExperiment._(this, id, ownerIsCurrent, snapshot.isCurrent);
  }
}

class CacheReservationExperiment {
  CacheReservationExperiment._(this._arbiter, this._id, this._ownerIsCurrent, this._measurementIsCurrent);
  final CacheReservationArbiterExperiment _arbiter;
  final Object _id;
  final bool Function() _ownerIsCurrent;
  final bool Function() _measurementIsCurrent;
  bool _started = false;
  bool _closed = false;

  /// Must be called immediately before dispatch; a stale owner cannot start.
  bool start() {
    if (_closed || _started || !_arbiter._reserved.containsKey(_id) ||
        !_arbiter._valid(_ownerIsCurrent) || !_arbiter._valid(_measurementIsCurrent)) return false;
    _started = true;
    return true;
  }

  /// Safe only before any filesystem/network/store work has been dispatched.
  bool cancelBeforeStart() {
    if (_closed || _started || !_arbiter._reserved.containsKey(_id)) return false;
    _arbiter._reserved.remove(_id);
    _arbiter._revision++;
    _closed = true;
    return true;
  }

  /// The caller must establish that all underlying writes and temporary-file
  /// cleanup have settled and that [measure] includes their physical result.
  /// If any proof is stale, the reservation is deliberately retained.
  Future<bool> settle({required bool Function() operationSettled,
      required CacheReservationMeasure measure}) async {
    if (_closed || !_started || !_arbiter._reserved.containsKey(_id) ||
        !_arbiter._valid(_ownerIsCurrent) || !_arbiter._valid(operationSettled)) return false;
    final revision = _arbiter._revision;
    CacheReservationSnapshot? snapshot;
    try { snapshot = await measure(); } catch (_) { return false; }
    if (snapshot == null || revision != _arbiter._revision ||
        !_arbiter._valid(_ownerIsCurrent) || !_arbiter._valid(operationSettled) ||
        !_arbiter._valid(snapshot.isCurrent)) return false;
    final estimate = CacheBudgetPolicyExperiment.estimate(snapshot.components,
        budgetBytes: _arbiter.temporaryBudgetBytes, complete: snapshot.complete);
    if (estimate == null || !estimate.budgetClassificationComplete ||
        revision != _arbiter._revision || !_arbiter._valid(_ownerIsCurrent) ||
        !_arbiter._valid(operationSettled) || !_arbiter._valid(snapshot.isCurrent)) return false;
    _arbiter._reserved.remove(_id);
    _arbiter._revision++;
    _closed = true;
    return true;
  }
}
