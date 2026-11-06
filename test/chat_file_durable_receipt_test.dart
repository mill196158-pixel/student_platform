import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> signInWithFileSession(
    SupabaseClient client, String uid, String sid) async {
  String b(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  await client.auth.recoverSession(jsonEncode({
    'access_token': '${b({'alg': 'HS256'})}.${b({
          'sub': uid,
          'exp': expiry,
          'session_id': sid
        })}.sig',
    'token_type': 'bearer',
    'refresh_token': 'test',
    'expires_at': expiry,
    'expires_in': 3600,
    'user': {
      'id': uid,
      'app_metadata': {},
      'user_metadata': {},
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z'
    },
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'authorized copy survives restart and denial retains bytes but revokes offline access',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('chat-receipt-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    var mode = 'allow';
    var requests = 0;
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/photo.png';
    const uid = 'receipt-user';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final transport = MockClient((request) async {
      requests++;
      if (mode == 'offline') throw const SocketException('offline');
      if (mode == 'auth401')
        return http.Response('{"error":"unauthorized"}', 401,
            request: request, headers: {'content-type': 'application/json'});
      if (mode == 'legacy403')
        return http.Response('{"error":"file_unavailable"}', 403,
            request: request, headers: {'content-type': 'application/json'});
      if (mode == 'legacy')
        return http.Response(
            jsonEncode({'url': url, 'cacheable': false, 'expiresIn': 60}), 200,
            request: request, headers: {'content-type': 'application/json'});
      if (mode == 'deny')
        return http.Response(
            '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
            request: request, headers: {'content-type': 'application/json'});
      return http.Response(
          jsonEncode({
            'url': url,
            'accessPolicyVersion': 1,
            'cacheable': false,
            'expiresIn': 60
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final key = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('$uid:$key'));
    final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await data.parent.create(recursive: true);
    await data.writeAsBytes([1, 2, 3]);

    // An old server must neither mint offline grants nor destroy bytes.
    mode = 'legacy';
    expect(await ChatFileAccess.resolve(url), url);
    await ChatFileAccess.authorize(url);
    expect(await File('${data.path}.grant').exists(), isFalse);
    expect(await data.readAsBytes(), [1, 2, 3]);
    mode = 'allow';
    // Even a previously non-cacheable attachment can be saved after an
    // explicit successful server authorization, as requested by the owner.
    expect(await ChatFileAccess.resolve(url), url);
    expect(await File('${data.path}.grant').exists(), isTrue);
    mode = 'auth401';
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    expect(await data.readAsBytes(), [1, 2, 3]);
    ChatFileAccess.debugResetProcessMemory();
    mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    mode = 'allow';
    await ChatFileAccess.resolve(url);
    // A downgrade to a legacy success fences a previously valid receipt.
    mode = 'legacy';
    expect(await ChatFileAccess.resolve(url), url);
    ChatFileAccess.debugResetProcessMemory();
    mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    mode = 'allow';
    await ChatFileAccess.resolve(url);
    // A legacy untyped 403 is not a confirmed revocation.
    mode = 'legacy403';
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    expect(ChatFileAccess.isAccessRevoked(url), isFalse);
    mode = 'allow';
    await ChatFileAccess.resolve(url);
    mode = 'offline';
    ChatFileAccess.debugResetProcessMemory();
    expect(
        await ChatFileAccess.readBytes(url).timeout(const Duration(seconds: 2)),
        [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Access denial blocks immediately and durably but does not delete bytes.
    mode = 'deny';
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    expect(await data.exists(), isTrue);
    expect(await File('${data.path}.denied').exists(), isTrue);
    ChatFileAccess.debugResetProcessMemory();
    mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    expect(await data.readAsBytes(), [1, 2, 3]);

    mode = 'allow';
    expect(await ChatFileAccess.resolve(url), url);
    expect(await File('${data.path}.denied').exists(), isFalse);
    mode = 'offline';
    expect(
        await ChatFileAccess.readBytes(url).timeout(const Duration(seconds: 2)),
        [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // A different session of the same account cannot consume the old receipt.
    await signInWithFileSession(
        Supabase.instance.client, uid, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    // Even if both durable denial mechanisms fail, the pre-request WAL
    // keeps the previous grant unavailable after a process restart.
    mode = 'allow';
    await ChatFileAccess.resolve(url);
    ChatFileAccess.debugFailDenialPersistence = true;
    mode = 'deny';
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    ChatFileAccess.debugFailDenialPersistence = false;
    expect(await File('${data.path}.pending').exists(), isTrue);
    expect(await data.readAsBytes(), [1, 2, 3]);
    ChatFileAccess.debugResetProcessMemory();
    mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    mode = 'allow';
    await ChatFileAccess.resolve(url);
    expect(await File('${data.path}.pending').exists(), isFalse);
    // If a per-file deny marker cannot be written, the owner directory is
    // quarantined so restart cannot expose the old grant. Bytes stay intact.
    mode = 'allow';
    expect(await ChatFileAccess.resolve(url), url);
    final markerObstacle = Directory('${data.path}.denied');
    await markerObstacle.create();
    mode = 'deny';
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    final parent = Directory('${dir.path}/authorized_chat_files');
    final quarantined = await parent
        .list()
        .where((e) => e is Directory && e.path.contains('.quarantined.'))
        .toList();
    expect(quarantined, hasLength(1));
    expect(await File('${quarantined.single.path}/$digest').readAsBytes(),
        [1, 2, 3]);
    ChatFileAccess.debugResetProcessMemory();
    mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    expect(requests, greaterThan(2));
  }, timeout: const Timeout(Duration(seconds: 15)));
}
