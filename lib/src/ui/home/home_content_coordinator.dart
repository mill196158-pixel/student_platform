import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/home_content_verified_loader.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:student_ui/student_ui.dart';

/// Owns verified local Home snapshots and refreshes them inside the online barrier.
class HomeContentCoordinator extends ChangeNotifier {
  HomeContentCoordinator(
      {required this.store, required this.scope, required this.httpClient});
  final HomeContentSnapshotStore store;
  final AuthSessionScope scope;
  final http.Client httpClient;
  final Map<String, AuthOperationScope> _denied = {};
  final Map<String, int> _denialRevision = {};
  final Map<String, int> _pendingDenials = {};
  bool isDenied(String section) {
    final owner = _denied[section];
    return owner != null && scope.isCurrent(owner);
  }

  Future<HomeContentSnapshot?> read(String section, SessionCapabilities caps) =>
      store.read(section, caps);

  Future<HomeContentSnapshot?> readOnline(
      String section, OnlineSideEffectBarrier barrier) async {
    final owner = scope.capture();
    if (owner == null || isDenied(section) || !barrier.isOpen) return null;
    final denialRevision = _denialRevision[section];
    final saved = await store.readOnline(section, barrier);
    return scope.isCurrent(owner) &&
            barrier.isOpen &&
            _denialRevision[section] == denialRevision &&
            !isDenied(section)
        ? saved
        : null;
  }

  Future<void> warm(
      HomeContentSection section, OnlineSideEffectBarrier barrier) async {
    await _refresh(section, barrier);
  }

  Future<PreparedHomePromos?> refreshPromo(
    OnlineSideEffectBarrier barrier, {
    Future<PreparedHomePromos?> Function(PreparedHomePromos)? prepare,
    void Function(Set<String>)? onVisibleIds,
  }) async {
    PreparedHomePromos? ready;
    final committed = await _refresh(
        HomeContentSection.promo, barrier,
        onVisibleIds: onVisibleIds, accept: (snapshot, livePromos) async {
      final candidate =
          PreparedHomePromos.fromSnapshot(snapshot, liveCards: livePromos);
      if (candidate == null) return false;
      ready = prepare == null ? candidate : await prepare(candidate);
      return ready != null;
    });
    return committed ? ready : null;
  }

  Future<bool> _refresh(
    HomeContentSection section,
    OnlineSideEffectBarrier barrier, {
    Future<bool> Function(HomeContentSnapshot, List<ManagedContentCard>)? accept,
    void Function(Set<String>)? onVisibleIds,
  }) async {
    final owner = scope.capture();
    if (owner == null) return false;
    bool current() => barrier.isOpen && scope.isCurrent(owner);
    final committed = await barrier.run(() async {
      final ticket = await store.begin(section.name, isCurrent: current);
      if (ticket == null || !current()) return false;
      final loader = HomeContentVerifiedLoader(
          client: SupabaseConfig.client,
          httpClient: httpClient,
          scope: scope,
          owner: owner,
          barrier: barrier,
          project: Uri.parse(SupabaseConfig.url),
          onPromoIdsConfirmed: section != HomeContentSection.promo
              ? null
              : (ids) async {
                  final retained = await store.retainPromoIds(ticket, ids);
                  if (!retained || !current()) return false;
                  onVisibleIds?.call(ids);
                  return current();
                },
          onAuthorizationDenial: () async {
            _pendingDenials[section.name] =
                (_pendingDenials[section.name] ?? 0) + 1;
            if (scope.isCurrent(owner)) {
              _denialRevision[section.name] =
                  (_denialRevision[section.name] ?? 0) + 1;
              _denied[section.name] = owner;
              notifyListeners();
            }
            try {
              final denied = await store.deny(ticket);
              if (!denied && scope.isCurrent(owner)) {
                throw StateError('Home content denial could not be recorded');
              }
            } finally {
              _pendingDenials[section.name] =
                  (_pendingDenials[section.name] ?? 1) - 1;
            }
          });
      final result = await loader.load(section);
      if (!current() || result.status != HomeContentLoadStatus.confirmed) {
        return false;
      }
      final beforeCommit = _denialRevision[section.name] ?? 0;
      final snapshot = HomeContentSnapshot(result.rows, result.media);
      if (accept != null && !await accept(snapshot, result.livePromos)) {
        return false;
      }
      if (!current() || (_denialRevision[section.name] ?? 0) != beforeCommit) {
        return false;
      }
      if (await store.commit(ticket, snapshot) &&
          current() &&
          (_denialRevision[section.name] ?? 0) == beforeCommit &&
          (_pendingDenials[section.name] ?? 0) == 0) {
        _denied.remove(section.name);
        notifyListeners();
        return current() && (_denialRevision[section.name] ?? 0) == beforeCommit;
      }
      return false;
    });
    return committed == true;
  }
}
