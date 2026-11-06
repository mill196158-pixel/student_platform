import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('logout fence blocks old and new reads while durable revoke waits',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('logout-fence-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const uid = 'a', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/f.bin';
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        String part(Object value) => base64Url
            .encode(utf8.encode(jsonEncode(value)))
            .replaceAll('=', '');
        final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        return http.Response(
            jsonEncode({
              'access_token': '${part({'alg': 'HS256'})}.${part({
                    'sub': 'c',
                    'exp': expiry,
                    'session_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
                  })}.sig',
              'token_type': 'bearer',
              'refresh_token': 'test',
              'expires_at': expiry,
              'expires_in': 3600,
              'user': {
                'id': 'c',
                'app_metadata': {},
                'user_metadata': {},
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z'
              }
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(
          jsonEncode(
              {'url': url, 'accessPolicyVersion': 1, 'cacheable': false}),
          200,
          request: request,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final reached = Completer<void>(), resume = Completer<void>();
    ChatFileAccess.debugBeforeForwardReturn = () async {
      reached.complete();
      await resume.future;
    };
    addTearDown(() async {
      ChatFileAccess.debugBeforeForwardReturn = null;
      if (!resume.isCompleted) resume.complete();
      ChatFileAccess.debugResetProcessMemory();
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await data.parent.create(recursive: true);
    await data.writeAsBytes([1, 2, 3]);
    await File('${data.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    final oldEpoch = ChatFileAccess.generation;
    final forward = ChatFileAccess.forwardTemp(url);
    final rejected = expectLater(forward, throwsStateError);
    await reached.future;
    final barrier = Completer<bool>();
    final logout = runLogoutCleanup(
      memoryFence: ChatFileAccess.fenceForLogout,
      durableRevoke: () => barrier.future,
      cleanups: [],
      signOut: () async => fail('must not sign out'),
      clearSession: () => fail('must not clear'),
    );
    expect(
        ChatFileAccess.isViewerCurrent(url,
            user: uid, epoch: oldEpoch, sessionBinding: sid),
        isFalse);
    await expectLater(ChatFileAccess.resolve(url), throwsStateError);
    resume.complete();
    await rejected;
    barrier.complete(false);
    expect(await logout, LogoutCleanupResult.blockedBeforeSignOut);
    expect(await data.readAsBytes(), [1, 2, 3]);
    await expectLater(ChatFileAccess.readBytes(url), throwsStateError);
    await signInWithFileSession(
        Supabase.instance.client, 'b', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    expect(
        ChatFileAccess.isViewerCurrent(url,
            user: uid, epoch: oldEpoch, sessionBinding: sid),
        isFalse);
    await expectLater(ChatFileAccess.resolve(url), throwsStateError);

    Object? fence;
    final uncertain = await runLogoutCleanup(
      memoryFence: () => fence = ChatFileAccess.fenceForLogout(),
      cleanups: [],
      signOut: () async {
        await Supabase.instance.client.auth.signOut();
        throw StateError('response lost after local session cleared');
      },
      clearSession: () {},
    );
    expect(uncertain, LogoutCleanupResult.signOutUnconfirmed);
    expect(Supabase.instance.client.auth.currentSession, isNull);
    ChatFileAccess.completeLogoutFence(fence!);
    await Supabase.instance.client.auth
        .signInWithPassword(email: 'c@example.test', password: 'test-password');
    await Future<void>.delayed(Duration.zero);
    expect(ChatFileAccess.isAccessRevoked(url), isFalse);
  });
}
