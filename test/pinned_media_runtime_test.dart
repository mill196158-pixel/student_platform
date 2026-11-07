import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
