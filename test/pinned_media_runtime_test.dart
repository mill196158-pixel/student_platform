import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/pinned_media_runtime.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('keeps protection through logout cleanup and rebinds a new owner', () async {
    final root = await Directory.systemTemp.createTemp('pinned-runtime-test-');
    SharedPreferences.setMockInitialValues({});
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => root.path);
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    await signInWithFileSession(Supabase.instance.client, 'a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final db = await openProjectChatServerDatabase('${root.path}/db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    Session? current = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current)); await scope.ready;
    final now = DateTime.now().toUtc();
    OfflineSessionBinding? binding() => current == null ? null : OfflineSessionBinding(
      issuer: 'https://example.test/auth/v1', userId: current!.user.id, sessionId: 'sid-${current!.user.id}',
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: binding, project: 'https://example.test');
    final runtime = PinnedMediaRuntime(scope: scope, cache: cache, currentSession: () => current,
        cacheDirectory: () async => root)..start();
    Future<void> waitFor(bool Function() ready) async {
      for (var i = 0; i < 200 && !ready(); i++) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
      expect(ready(), isTrue);
    }
    await waitFor(() => ChatFileAccess.mediaProtection != null);
    final first = ChatFileAccess.mediaProtection!;
    final readStarted = Completer<void>(), releaseRead = Completer<void>();
    final oldRead = first.readInOwnerWindow('a', () => true, () async {
      readStarted.complete(); await releaseRead.future; return 'old';
    });
    await readStarted.future;
    scope.invalidateForSignOut();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(identical(ChatFileAccess.mediaProtection, first), isTrue, reason: 'logout cleanup still needs old lease');
    final cacheDir = Directory('${root.path}/authorized_chat_files/a'); await cacheDir.create(recursive: true);
    final synthetic = File('${cacheDir.path}/file'); await synthetic.writeAsBytes([1]);
    await ChatFileAccess.clear();
    expect(await cacheDir.exists(), isFalse, reason: 'logout cleanup uses the still-live protection');
    current = null; events.add(AuthState(AuthChangeEvent.signedOut, null));
    await waitFor(() => ChatFileAccess.mediaProtection == null);
    current = fakeSession('b'); events.add(AuthState(AuthChangeEvent.signedIn, current));
    await waitFor(() => ChatFileAccess.mediaProtection != null && !identical(ChatFileAccess.mediaProtection, first));
    expect(ChatFileAccess.mediaProtection!.currentOwner(), 'b');
    releaseRead.complete();
    await expectLater(oldRead, throwsStateError);
    await runtime.dispose(); await db.close(); scope.dispose(); await events.close();
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });

  test('failed recovery retries manually; delayed recovery is never published early', () async {
    final root = await Directory.systemTemp.createTemp('pinned-runtime-retry-');
    SharedPreferences.setMockInitialValues({});
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => root.path);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/retry.png';
    final transport = MockClient((request) async => http.Response('{"url":"$url","accessPolicyVersion":1,"cacheable":false,"expiresIn":60}',
      200, request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test', httpClient: transport,
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await signInWithFileSession(Supabase.instance.client, 'a', sid);
    final db = await openProjectChatServerDatabase('${root.path}/db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session)); await scope.ready;
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://example.test/auth/v1', userId: 'a', sessionId: sid,
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: () => binding, project: 'https://example.test');
    var failures = 0;
    debugBeforePinnedRecovery = () async { failures++; throw StateError('temporary failure'); };
    final runtime = PinnedMediaRuntime(scope: scope, cache: cache, currentSession: () => session,
        cacheDirectory: () async => root)..start();
    for (var i = 0; i < 100 && failures == 0; i++) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(failures, greaterThan(0));
    expect(ChatFileAccess.mediaProtection, isNull);
    final recovery = Completer<void>(); var secondStarted = false;
    debugBeforePinnedRecovery = () async { secondStarted = true; await recovery.future; };
    runtime.retry();
    for (var i = 0; i < 100 && !secondStarted; i++) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(secondStarted, isTrue);
    expect(ChatFileAccess.mediaProtection, isNull, reason: 'not ready while recovery is pending');
    recovery.complete();
    for (var i = 0; i < 100 && ChatFileAccess.mediaProtection == null; i++) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(ChatFileAccess.mediaProtection, isNotNull);
    expect(await ChatFileAccess.resolve(url), url);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    debugBeforePinnedRecovery = null;
    await runtime.dispose(); await db.close(); scope.dispose(); await events.close(); await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null); await root.delete(recursive: true);
  }, skip: !const bool.fromEnvironment('PINNED_MEDIA_RUNTIME'));
}
