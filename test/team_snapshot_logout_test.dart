import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/ui/learning/state/team_assignment_snapshot_store.dart';
import 'package:student_platform/src/ui/learning/state/team_cache_owner.dart';
import 'package:student_platform/src/ui/learning/state/team_snapshot_logout.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Storage implements TeamSnapshotStorage {
  final values = <String, String>{};
  Completer<void>? entered, release;
  @override
  Future<Set<String>> keys() async {
    entered?.complete();
    await release?.future;
    return values.keys.toSet();
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }
}

void main() {
  test('timeout reports incomplete but signout proceeds and cleanup continues',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = TeamCacheOwner.bind(scope, 'team')!;
    final storage = _Storage()
      ..entered = Completer()
      ..release = Completer();
    final coordinator = TeamSnapshotCoordinator(storage);
    final store = TeamAssignmentSnapshotStore(
        owner: owner, project: 'project', coordinator: coordinator);
    final cleanup = beginTeamSnapshotLogout(
        coordinator: coordinator,
        project: 'project',
        userId: 'a',
        timeout: const Duration(milliseconds: 10));
    expect(store.beginLoad(), isNull);
    await storage.entered!.future;
    var signedOut = false;
    final complete = await runLogoutCleanup(
        cleanups: [
          () async {
            if (!await cleanup) throw StateError('incomplete');
          }
        ],
        signOut: () async {
          signedOut = true;
        },
        clearSession: () {});
    expect(complete, LogoutCleanupResult.signedOutCleanupIncomplete);
    expect(signedOut, isTrue);
    expect(store.beginLoad(), isNull);
    storage.release!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(store.beginLoad(), isNotNull);
    store.dispose();
    owner.dispose();
    scope.dispose();
    await events.close();
  });
  test('unattributed corrupt entries report incomplete without deletion',
      () async {
    final storage = _Storage()..values['team_assign_v2_unknown'] = '{broken';
    expect(
        await beginTeamSnapshotLogout(
            coordinator: TeamSnapshotCoordinator(storage),
            project: 'project',
            userId: 'a'),
        isFalse);
    expect(storage.values['team_assign_v2_unknown'], '{broken');
  });
}
