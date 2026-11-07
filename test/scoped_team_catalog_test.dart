import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/scoped_team_catalog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Session _session(String uid, String sid) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object x) =>
      base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
  final token = '${part({'alg': 'HS256'})}.${part({
        'iss': 'https://example.invalid/auth/v1',
        'sub': uid,
        'session_id': sid,
        'role': 'authenticated',
        'aud': 'authenticated',
        'iat': now - 60,
        'exp': now + 3600
      })}.sig';
  return Session(
      accessToken: token,
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
      'scoped catalog preserves order and rejects superseded/account-switched tickets',
      () async {
    final root = await Directory.systemTemp.createTemp('team-catalog-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/cache.db');
    const sidA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const sidB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    var session = _session('a', sidA);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    void grant(SessionCapabilityMode mode) => expect(
        caps.grant(mode, caps.beginAuthorization(scope.capture()!)!), isTrue);
    OfflineSessionBinding? binding() => OfflineSessionBinding.fromSession(
        session, 'https://example.invalid/auth/v1');
    final store = ScopedTeamCatalogStore(
        db: db,
        scope: scope,
        currentBinding: binding,
        project: 'https://example.invalid');
    addTearDown(() async {
      caps.dispose();
      scope.dispose();
      await events.close();
      await db.close();
      await root.delete(recursive: true);
    });
    final teams = [
      const Team(
          id: 's',
          name: 'Subject',
          teacher: 'T',
          groupCode: 'G',
          icon: '',
          kind: 'subject'),
      const Team(
          id: 'u',
          name: 'Unknown',
          teacher: '',
          groupCode: '',
          icon: '',
          kind: 'unknown')
    ];
    grant(SessionCapabilityMode.online);
    final old = (await store.begin(caps))!, latest = (await store.begin(caps))!;
    expect(await store.commit(old, caps, teams, DateTime.utc(2026)), isFalse);
    expect(await store.commit(latest, caps, teams, DateTime.utc(2026)), isTrue);
    final raced = (await store.begin(caps))!;
    final denialStarted = Completer<void>(), releaseDenial = Completer<void>();
    store.debugBeforeDenialCommit = () async {
      denialStarted.complete();
      await releaseDenial.future;
    };
    final denial = store.deny(latest);
    await denialStarted.future;
    expect(await store.commit(raced, caps, teams, DateTime.utc(2026)), isFalse,
        reason:
            'pending denial prevents publishing before its database commit');
    releaseDenial.complete();
    expect(await denial, isTrue,
        reason: 'confirmed late denial supersedes newer in-flight response');
    store.debugBeforeDenialCommit = null;
    expect(await store.commit(raced, caps, teams, DateTime.utc(2026)), isFalse);
    final stored = await db.query('scoped_team_catalog');
    expect(stored.single['denied'], 1);
    expect(stored.single['payload'], isNotNull,
        reason: 'denial preserves bytes for rollback');
    grant(SessionCapabilityMode.cacheOnly);
    expect(await store.read(caps), isNull);
    grant(SessionCapabilityMode.online);
    final reauthorized = (await store.begin(caps))!;
    expect(await store.commit(reauthorized, caps, teams, DateTime.utc(2026)),
        isTrue);
    final other = ScopedTeamCatalogStore(
        db: db,
        scope: scope,
        currentBinding: binding,
        project: 'https://example.invalid');
    expect(
        await other.commit(latest, caps, teams, DateTime.utc(2026)), isFalse);
    grant(SessionCapabilityMode.cacheOnly);
    final snapshot = await store.read(caps);
    expect(snapshot!.teams.map((t) => t.id), ['s', 'u']);
    expect(snapshot.teams.last.kind, 'unknown');
    session = _session('b', sidB);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await store.deny(latest), isFalse,
        reason: 'late denial cannot alter another session');
    expect(await store.read(caps), isNull);
    grant(SessionCapabilityMode.cacheOnly);
    expect(await store.read(caps), isNull);
    session = _session('a', sidA);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    grant(SessionCapabilityMode.online);
    expect(
        await store.commit(latest, caps, teams, DateTime.utc(2026)), isFalse);
    grant(SessionCapabilityMode.cacheOnly);
    expect((await store.read(caps))!.teams.map((t) => t.id), ['s', 'u']);
  });
  test('additive denial migration retains existing catalog payload', () async {
    final root = await Directory.systemTemp.createTemp('team-catalog-migrate-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/cache.db');
    await db.execute(
        'CREATE TABLE scoped_team_catalog (project TEXT NOT NULL, uid TEXT NOT NULL, '
        'sid TEXT NOT NULL, seq INTEGER NOT NULL, saved_at INTEGER, payload TEXT, PRIMARY KEY(project,uid,sid))');
    await db.insert('scoped_team_catalog', {
      'project': 'https://example.invalid',
      'uid': 'a',
      'sid': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'seq': 3,
      'saved_at': 1,
      'payload': '[]'
    });
    final session = _session('a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    final store = ScopedTeamCatalogStore(
        db: db,
        scope: scope,
        currentBinding: () => OfflineSessionBinding.fromSession(
            session, 'https://example.invalid/auth/v1'),
        project: 'https://example.invalid');
    expect((await store.read(caps))!.teams, isEmpty);
    final rows = await db.query('scoped_team_catalog');
    expect(rows.single['payload'], '[]');
    expect(rows.single['seq'], 3);
    expect(rows.single['denied'], 0);
    caps.dispose();
    scope.dispose();
    await events.close();
    await db.close();
    await root.delete(recursive: true);
  });
}
