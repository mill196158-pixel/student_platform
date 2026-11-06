import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/home_content_verified_loader.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';

/// QA-only: persists verified online content for a later local-only read.
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

  Future<void> warm(
      HomeContentSection section, OnlineSideEffectBarrier barrier) async {
    final owner = scope.capture();
    if (owner == null) return;
    bool current() => barrier.isOpen && scope.isCurrent(owner);
    await barrier.run(() async {
      final ticket = await store.begin(section.name, isCurrent: current);
      if (ticket == null || !current()) return;
      final loader = HomeContentVerifiedLoader(
          client: SupabaseConfig.client,
          httpClient: httpClient,
          scope: scope,
          owner: owner,
          barrier: barrier,
          project: Uri.parse(SupabaseConfig.url),
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
      if (!current() || result.status != HomeContentLoadStatus.confirmed)
        return;
      final beforeCommit = _denialRevision[section.name] ?? 0;
      if (await store.commit(
              ticket, HomeContentSnapshot(result.rows, result.media)) &&
          current() &&
          (_denialRevision[section.name] ?? 0) == beforeCommit &&
          (_pendingDenials[section.name] ?? 0) == 0) {
        _denied.remove(section.name);
        notifyListeners();
      }
    });
  }
}
