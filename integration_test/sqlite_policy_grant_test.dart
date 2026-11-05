import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Session _session(String uid, {String token = 'token'}) => Session(
    accessToken: token,
    refreshToken: 'refresh',
    tokenType: 'bearer',
    user: User(
        id: uid,
        appMetadata: const {},
        userMetadata: null,
        aud: '',
        createdAt: ''));

class _CommitHookDatabase implements Database {
  _CommitHookDatabase(this.inner, this.afterTransaction);
  final Database inner;
  final Future<void> Function(int) afterTransaction;
  int count = 0;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
      {bool? exclusive}) async {
    final result = await inner.transaction(action, exclusive: exclusive);
    await afterTransaction(++count);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late String path;
  late Database db;
  late StreamController<AuthState> events;
  late Session session;
  late AuthSessionScope scope;
  late OfflineSessionBinding binding;
  late SqlitePolicyGrantStore store;
  var now = DateTime.utc(2026, 11, 5, 12);
  var sequence = 0;
  setUp(() async {
    if ((await PackageInfo.fromPlatform()).packageName !=
        'com.example.offline_grant_qa') {
      throw StateError('Run only in the isolated offline_grant_qa app');
    }
    now = DateTime.utc(2026, 11, 5, 12);
    path =
        '${await getDatabasesPath()}/codex_policy_qa_${DateTime.now().microsecondsSinceEpoch}_${sequence++}.db';
    if (await databaseExists(path))
      throw StateError('QA database already exists');
    db = await openPolicyGrantDatabase(path);
    events = StreamController<AuthState>.broadcast(sync: true);
    session = _session('a');
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    binding = OfflineSessionBinding(
        issuer: 'https://test.invalid/auth/v1',
        userId: 'a',
        sessionId: '12345678-1234-1234-1234-123456789012',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
  });
  tearDown(() async {
    store.dispose();
    scope.dispose();
    await events.close();
    await db.close();
    await deleteDatabase(path);
  });
  OfflinePolicyGrant grant() => OfflinePolicyGrant(
      issuer: binding.issuer,
      userId: binding.userId,
      sessionId: binding.sessionId,
      checkedAt: now,
      validUntil: now.add(const Duration(minutes: 30)));

  testWidgets('real SQLite commit survives reopen and revoke survives reopen',
      (tester) async {
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    final sync = await db.rawQuery('PRAGMA synchronous');
    expect(sync.first.values.single, 2);
    store.dispose();
    await db.close();
    db = await openPolicyGrantDatabase(path);
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    final revoke = store.beginRevoke(binding);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
    expect((await revoke).epoch, greaterThan(0));
    store.dispose();
    await db.close();
    db = await openPolicyGrantDatabase(path);
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('latest live attempt wins and old owner cannot write',
      (tester) async {
    final first = (await store.beginLiveCheck(scope.capture()!, binding))!;
    final second = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(first, grant()), isFalse);
    expect(await store.saveAllowed(second, grant()), isTrue);
    final third = (await store.beginLiveCheck(scope.capture()!, binding))!;
    session = _session('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = _session('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await store.saveAllowed(third, grant()), isFalse);
  });

  testWidgets('clock rollback blocks candidate', (tester) async {
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    now = now.subtract(const Duration(minutes: 1));
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('failed revoke rolls its owner update back', (tester) async {
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    final before = await db.rawQuery('SELECT epoch,state FROM policy_owner');
    await db.execute('DROP TABLE policy_grant');
    await expectLater(store.beginRevoke(binding), throwsA(anything));
    final after = await db.rawQuery('SELECT epoch,state FROM policy_owner');
    expect(after, before);
  });

  testWidgets('failed stale-commit cleanup keeps candidate blocked',
      (tester) async {
    final proxy = _CommitHookDatabase(db, (count) async {
      if (count == 2) {
        session = _session('a', token: 'new-session');
        events.add(AuthState(AuthChangeEvent.signedIn, session));
        await db.execute('DROP TABLE policy_grant');
      }
    });
    store.dispose();
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(proxy),
        clock: () => now);
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    await expectLater(store.saveAllowed(attempt, grant()), throwsA(anything));
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('successful stale cleanup allows a newer queued live check',
      (tester) async {
    Future<SqliteLiveGrantAttempt?>? newer;
    final proxy = _CommitHookDatabase(db, (count) async {
      if (count == 2) {
        session = _session('a', token: 'new-session');
        events.add(AuthState(AuthChangeEvent.signedIn, session));
        newer = store.beginLiveCheck(scope.capture()!, binding);
      }
    });
    store.dispose();
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(proxy),
        clock: () => now);
    final old = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(old, grant()), isFalse);
    final fresh = await newer!;
    expect(fresh, isNotNull);
    expect(await store.saveAllowed(fresh!, grant()), isTrue);
  });

  testWidgets('old binding cannot extend a rotated token expiry',
      (tester) async {
    final oldBinding = binding;
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    session = _session('a', token: 'rotated');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    binding = OfflineSessionBinding(
        issuer: oldBinding.issuer,
        userId: oldBinding.userId,
        sessionId: oldBinding.sessionId,
        notBefore: oldBinding.notBefore,
        expiresAt: now.add(const Duration(minutes: 10)));
    now = now.add(const Duration(minutes: 20));
    expect((await store.readCandidate(scope.capture()!, oldBinding)).status,
        SqliteGrantReadStatus.blocked);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('invalid counters cannot become an eligible candidate',
      (tester) async {
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    await db.execute('PRAGMA ignore_check_constraints=ON');
    await db.rawUpdate('UPDATE policy_owner SET epoch=-1');
    await db.rawUpdate('UPDATE policy_grant SET owner_epoch=-1');
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('candidate expires while its read transaction commits',
      (tester) async {
    final proxy = _CommitHookDatabase(db, (count) async {
      if (count == 3) now = now.add(const Duration(minutes: 31));
    });
    store.dispose();
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(proxy),
        clock: () => now);
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('backward clock movement during commit blocks candidate',
      (tester) async {
    final proxy = _CommitHookDatabase(db, (count) async {
      if (count == 3) now = now.subtract(const Duration(seconds: 1));
    });
    store.dispose();
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(proxy),
        clock: () => now);
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(await store.saveAllowed(attempt, grant()), isTrue);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
  });

  testWidgets('unknown future schema is rejected without recreation',
      (tester) async {
    final futurePath = '${path}_future';
    if (await databaseExists(futurePath))
      throw StateError('QA database already exists');
    var futureDb = await databaseFactory.openDatabase(futurePath,
        options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE marker (value TEXT)');
              await db.rawInsert(
                  'INSERT INTO marker(value) VALUES (?)', ['intact']);
            }));
    await futureDb.close();
    await expectLater(openPolicyGrantDatabase(futurePath), throwsA(anything));
    futureDb = await databaseFactory.openDatabase(futurePath,
        options: OpenDatabaseOptions(version: 2));
    expect(
        (await futureDb.rawQuery('SELECT value FROM marker')).single['value'],
        'intact');
    await futureDb.close();
    await deleteDatabase(futurePath);
  });

  testWidgets('invalid version-one schema is rejected without recreation',
      (tester) async {
    final badPath = '${path}_bad';
    if (await databaseExists(badPath))
      throw StateError('QA database already exists');
    var badDb = await databaseFactory.openDatabase(badPath,
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE marker (value TEXT)');
              await db.rawInsert(
                  'INSERT INTO marker(value) VALUES (?)', ['intact']);
            }));
    await badDb.close();
    await expectLater(openPolicyGrantDatabase(badPath), throwsA(anything));
    badDb = await databaseFactory.openDatabase(badPath,
        options: OpenDatabaseOptions(version: 1));
    expect((await badDb.rawQuery('SELECT value FROM marker')).single['value'],
        'intact');
    await badDb.close();
    await deleteDatabase(badPath);
  });
}
