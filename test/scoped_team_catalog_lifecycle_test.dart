import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/learning_cubit.dart';
import 'package:student_platform/src/ui/learning/state/scoped_team_catalog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repo implements LearningRepository {
  @override
  Future<List<Team>> loadTeams(String group) async => [];
  @override
  Future<Set<String>> loadHiddenTeamIds() async => {};
  @override
  Future<String?> loadViewMode() async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Session _session(String uid, String sid) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object x) =>
      base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
  return Session(
      accessToken: '${part({'alg': 'HS256'})}.${part({
            'iss': 'https://example.invalid/auth/v1',
            'sub': uid,
            'session_id': sid,
            'role': 'authenticated',
            'aud': 'authenticated',
            'iat': now - 60,
            'exp': now + 3600
          })}.sig',
      refreshToken: 'local',
      tokenType: 'bearer',
      user: User(
          id: uid,
          appMetadata: const {},
          userMetadata: null,
          aud: 'authenticated',
          createdAt: ''));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
      'inflight catalog is drained, never published after offline or scope change',
      () async {
    final root =
        await Directory.systemTemp.createTemp('team-catalog-lifecycle-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/cache.db');
    var session = _session('a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.online,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    final owner = scope.capture()!;
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => scope.isCurrent(owner));
    OfflineSessionBinding? binding() => OfflineSessionBinding.fromSession(
        session, 'https://example.invalid/auth/v1');
    final store = ScopedTeamCatalogStore(
        db: db,
        scope: scope,
        currentBinding: binding,
        project: 'https://example.invalid');
    final pending = Completer<List<Team>>(), started = Completer<void>();
    var calls = 0;
    final cubit = LearningCubit(
        repository: _Repo(),
        catalogStore: store,
        catalogCapabilities: caps,
        catalogBarrier: barrier,
        debugConfirmedCatalog: () {
          calls++;
          started.complete();
          return pending.future;
        });
    addTearDown(() async {
      await cubit.close();
      caps.dispose();
      scope.dispose();
      await events.close();
      await db.close();
      await root.delete(recursive: true);
    });
    await cubit.load('G');
    await started.future;
    expect(barrier.activeCount, 1);
    expect(
        await barrier.closeAndDrain(timeout: const Duration(milliseconds: 10)),
        isFalse);
    expect(barrier.activeCount, 1,
        reason: 'timeout did not cancel the request');
    session = _session('b', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    pending.complete([
      const Team(
          id: 's',
          name: 'Sensitive',
          teacher: '',
          groupCode: '',
          icon: '',
          kind: 'subject')
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(barrier.activeCount, 0);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    expect(await store.read(caps), isNull);
    await cubit.load('G');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1,
        reason: 'closed barrier never dispatches another catalog request');
  });
  test(
      'late catalog denial leaves other cached capability available and preserves bytes',
      () async {
    final root = await Directory.systemTemp.createTemp('team-catalog-denial-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/cache.db');
    final session = _session('a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    void grant(SessionCapabilityMode mode) => expect(
        caps.grant(mode, caps.beginAuthorization(scope.capture()!)!), isTrue);
    grant(SessionCapabilityMode.online);
    final owner = scope.capture()!;
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => scope.isCurrent(owner));
    final store = ScopedTeamCatalogStore(
        db: db,
        scope: scope,
        currentBinding: () => OfflineSessionBinding.fromSession(
            session, 'https://example.invalid/auth/v1'),
        project: 'https://example.invalid');
    final seed = (await store.begin(caps))!;
    final teams = [
      const Team(
          id: 's',
          name: 'Subject',
          teacher: '',
          groupCode: '',
          icon: '',
          kind: 'subject')
    ];
    expect(await store.commit(seed, caps, teams, DateTime.utc(2026)), isTrue);
    final pending = Completer<List<Team>>(), started = Completer<void>();
    final cubit = LearningCubit(
        repository: _Repo(),
        catalogStore: store,
        catalogCapabilities: caps,
        catalogBarrier: barrier,
        debugConfirmedCatalog: () {
          started.complete();
          return pending.future;
        });
    await cubit.load('G');
    await started.future;
    expect(
        await barrier.closeAndDrain(timeout: const Duration(milliseconds: 10)),
        isFalse);
    grant(SessionCapabilityMode.cacheOnly);
    expect(await store.read(caps), isNotNull);
    pending.completeError(
        const PostgrestException(message: 'denied', code: '42501'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(caps.mode, SessionCapabilityMode.cacheOnly);
    expect(caps.capture(SessionCapability.cachedRead), isNotNull);
    expect(await store.read(caps), isNull);
    final rows = await db.query('scoped_team_catalog');
    expect(rows.single['denied'], 1);
    expect(rows.single['payload'], isNotNull);
    grant(SessionCapabilityMode.online);
    final next = (await store.begin(caps))!;
    expect(await store.commit(next, caps, teams, DateTime.utc(2026)), isTrue);
    grant(SessionCapabilityMode.cacheOnly);
    expect(await store.read(caps), isNotNull);
    await cubit.close();
    caps.dispose();
    scope.dispose();
    await events.close();
    await db.close();
    await root.delete(recursive: true);
  });
}
