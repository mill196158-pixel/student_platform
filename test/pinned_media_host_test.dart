import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/pinned_media_host.dart';
import 'package:student_platform/src/core/pinned_media_availability.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('separate guard DB failure preserves legacy and retries online admission', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('pinned-host-test-');
    final invalid = File('${root.path}/not-directory'); await invalid.writeAsString('untouched');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/host.png';
    const uid = 'a', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final transport = MockClient((request) async => http.Response(jsonEncode({
      'url': url, 'accessPolicyVersion': 1, 'cacheable': false, 'expiresIn': 60,
    }), 200, request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test', httpClient: transport,
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession(uid);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session)); await scope.ready;
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://example.test/auth/v1', userId: uid, sessionId: sid,
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    var healthy = false, attempts = 0;
    final host = PinnedMediaHost(scope: scope, project: 'https://example.test', currentSession: () => session,
      currentBinding: () => binding, supportDirectory: () async { attempts++; return healthy ? root : Directory(invalid.path); },
      cacheDirectory: () async => root, databaseFactory: databaseFactoryFfi,
      retryDelays: const [Duration(milliseconds: 30), Duration(milliseconds: 30), Duration(milliseconds: 30)])..start();
    final key = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('$uid:$key'));
    final file = File('${root.path}/authorized_chat_files/$uid/$digest'); await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]); await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(ChatFileAccess.mediaProtection, isNull);
    expect(attempts, 4, reason: 'automatic retries are bounded');
    expect(PinnedMediaAvailability.state.value, PinnedMediaAvailabilityState.unavailable);
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), [1, 2, 3]);
    await expectLater(ChatFileAccess.resolve(url), throwsA(isA<MediaProtectionUnavailable>()));
    expect(await invalid.readAsString(), 'untouched');
    healthy = true;
    PinnedMediaAvailability.retry();
    for (var i = 0; i < 250 && ChatFileAccess.mediaProtection == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ChatFileAccess.mediaProtection, isNotNull);
    expect(await ChatFileAccess.resolve(url), url);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await host.dispose(); scope.dispose(); await events.close(); await Supabase.instance.dispose();
    messenger.setMockMethodCallHandler(paths, null); await root.delete(recursive: true);
  }, skip: !const bool.fromEnvironment('PINNED_MEDIA_RUNTIME'));
}
