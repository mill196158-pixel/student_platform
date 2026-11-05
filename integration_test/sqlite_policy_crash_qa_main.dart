// Manual Android QA entry point. Run only in the isolated QA application id.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _PauseBeforeCommit implements Database {
  _PauseBeforeCommit(this.inner, this.status);
  final Database inner;
  final File status;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      inner.transaction((txn) async {
        final result = await action(txn);
        await status.writeAsString('before', flush: true);
        await Completer<void>().future;
        return result;
      }, exclusive: exclusive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('SQLite QA')))));
  if (!Platform.isAndroid ||
      (await PackageInfo.fromPlatform()).packageName !=
          'com.example.offline_grant_qa') {
    throw StateError('Run only in the isolated offline_grant_qa app');
  }
  final directory = await getDatabasesPath();
  final status = File('$directory/codex_policy_crash_status.txt');
  final dbPath = '$directory/codex_policy_crash_qa.db';
  try {
    final phase = await status.exists() ? await status.readAsString() : '';
    if (phase.isEmpty) await deleteDatabase(dbPath);
    final db = await openPolicyGrantDatabase(dbPath);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Session(
        accessToken: 'fake',
        refreshToken: 'fake',
        tokenType: 'bearer',
        user: User(
            id: 'qa',
            appMetadata: const {},
            userMetadata: null,
            aud: '',
            createdAt: ''));
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.utc(2026, 11, 5, 12);
    final binding = OfflineSessionBinding(
        issuer: 'https://qa.invalid/auth/v1',
        userId: 'qa',
        sessionId: '12345678-1234-1234-1234-123456789012',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    SqlitePolicyGrantStore makeStore(Database database) =>
        SqlitePolicyGrantStore(
            scope: scope,
            currentBinding: () => binding,
            coordinator: SqlitePolicyGrantCoordinator(database),
            clock: () => now);
    final store = makeStore(db);
    if (phase.isEmpty) {
      final attempt = await store.beginLiveCheck(scope.capture()!, binding);
      if (attempt == null ||
          !await store.saveAllowed(
              attempt,
              OfflinePolicyGrant(
                  issuer: binding.issuer,
                  userId: binding.userId,
                  sessionId: binding.sessionId,
                  checkedAt: now,
                  validUntil: now.add(const Duration(minutes: 30))))) {
        throw StateError('seed failed');
      }
      final paused = makeStore(_PauseBeforeCommit(db, status));
      await paused.beginRevoke(binding);
    } else if (phase == 'before') {
      if ((await store.readCandidate(scope.capture()!, binding)).status !=
          SqliteGrantReadStatus.found) {
        throw StateError('uncommitted transaction was not rolled back');
      }
      await store.beginRevoke(binding);
      await status.writeAsString('after', flush: true);
      await Completer<void>().future;
    } else if (phase == 'after') {
      if ((await store.readCandidate(scope.capture()!, binding)).status !=
          SqliteGrantReadStatus.blocked) {
        throw StateError('committed revoke was not retained');
      }
      await status.writeAsString('passed', flush: true);
    }
  } catch (error) {
    await status.writeAsString('failed:${error.runtimeType}', flush: true);
  }
}
