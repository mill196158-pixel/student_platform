import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/qa_rotation_receipt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/attachments/chat_attachments_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _PutAdapter implements HttpClientAdapter {
  int count = 0;
  final bodies = <Uint8List>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    expect(options.uri.host, 'upload.invalid');
    final data = BytesBuilder(copy: false);
    if (stream != null)
      await for (final part in stream) {
        data.add(part);
      }
    bodies.add(data.takeBytes());
    count++;
    return ResponseBody.fromString(count == 2 ? 'synthetic failure' : 'ok',
        count == 2 ? 500 : 200);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _session(String uid, int version) {
  String part(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'access_token': '${part({'alg': 'none'})}.${part({
          'sub': uid,
          'session_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'iat': now,
          'exp': now + 3600,
          'version': version
        })}.sig',
    'refresh_token': 'synthetic-$version',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': now + 3600,
    'user': {
      'id': uid,
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z'
    }
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const strict = bool.fromEnvironment('CHAT_ATTACHMENT_SESSION_FENCE_QA');
  test('QA explicit retry after verified rotation and pre-dispatch failure',
      () async {
    SharedPreferences.setMockInitialValues({});
    const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final initial = _session(uid, 1), rotated = _session(uid, 2);
    var refreshes = 0, presigns = 0, confirms = 0, saves = 0;
    final clientMock = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/auth/v1/token')) {
        expect(request.url.queryParameters['grant_type'], 'refresh_token');
        refreshes++;
        return http.Response(jsonEncode(refreshes == 1 ? rotated : _session(uid, 3)), 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      if (path.endsWith('/generate-upload-url')) {
        presigns++;
        return http.Response(
            jsonEncode({
              'uploadUrl': 'https://upload.invalid/object',
              'fileKey': 'chats/test/object',
              'fileUrl': 'https://example.invalid/object',
              'headers': {'Content-Type': 'image/jpeg'}
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request);
      }
      if (path.endsWith('/chat-file-access')) {
        confirms++;
        return http.Response('{"confirmed":true}', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      if (path.endsWith('/rpc/save_chat_file')) {
        saves++;
        return http.Response('"synthetic-file-id"', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      fail('Unexpected HTTP path ${request.url.path}');
    });
    await Supabase.initialize(
        url: 'https://example.invalid',
        publishableKey: 'test',
        httpClient: clientMock,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(initial));
    final adapter = _PutAdapter(), dio = Dio()..httpClientAdapter = adapter;
    final service = FileService(supabase: client, dio: dio);
    final dir = await Directory.systemTemp.createTemp('chat_real_refresh_');
    final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    final file = File('${dir.path}/original.jpg');

    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, client.auth.currentSession));
    await scope.ready;
    final caps = SessionCapabilities(scope);
    final owner = scope.capture()!;
    expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(owner)!), isTrue);
    final receipt = QaRotationReceipt();
    final controller = ChatAttachmentsController(service, GlobalCache(), client,
        authScope: scope, capabilities: caps, rotationReceipt: receipt);
    final attach = LocalAttach(
        path: file.path,
        name: 'original.jpg',
        mimeType: 'image/jpeg',
        size: bytes.length,
        isImage: true,
        preserveOriginal: true);
    expect(controller.add(attach), isTrue);
    await controller.upload(attach, chatId: 'chat');
    expect(controller.pending.single.isFailed, isTrue);
    expect(presigns, 0);
    expect(adapter.count, 0);
    expect(confirms, 0);
    expect(saves, 0);
    final originalSession = client.auth.currentSession;
    var asyncRefreshSeen = false, getterAdvancedBeforeAsync = false;
    final asyncSub = client.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.tokenRefreshed)
        asyncRefreshSeen = true;
    });
    // Test-only SDK seam: this internal synchronous stream is never used by app code.
    // ignore: invalid_use_of_internal_member
    final syncSub = client.auth.onAuthStateChangeSync.listen((event) {
      if (event.event == AuthChangeEvent.tokenRefreshed) {
        getterAdvancedBeforeAsync =
            !identical(client.auth.currentSession, originalSession) &&
                !asyncRefreshSeen;
      }
    });
    try {
      final response = await client.auth.refreshSession();
      expect(refreshes, 1);
      expect(response.session?.user.id, uid);
      expect(identical(response.session, client.auth.currentSession), isTrue);
      expect(
          response.session!.accessToken, isNot(originalSession!.accessToken));
      expect(
          response.session!.refreshToken, isNot(originalSession.refreshToken));
      Map<String, dynamic> claims(String token) =>
          Map<String, dynamic>.from(jsonDecode(utf8.decode(
                  base64Url.decode(base64Url.normalize(token.split('.')[1]))))
              as Map);
      expect(claims(response.session!.accessToken)['session_id'],
          claims(originalSession.accessToken)['session_id']);
      expect(getterAdvancedBeforeAsync, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(asyncRefreshSeen, isTrue);
      events.add(AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession));
      final nextOwner = scope.capture()!;
      expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(nextOwner)!), isTrue);
      await file.writeAsBytes(bytes);
      await controller.retry(controller.pending.single, chatId: 'chat');
      expect(presigns, 0, reason: 'A live capability alone is not a rotation receipt');
      expect(await file.readAsBytes(), orderedEquals(bytes));
      receipt.record(owner, nextOwner, caps);
      await controller.retry(controller.pending.single, chatId: 'wrong-chat');
      expect(presigns, 0, reason: 'Retry cannot change the captured target');
      var canCompose = true;
      final delayedRetry = controller.retry(controller.pending.single, chatId: 'chat',
          canDispatch: () => canCompose);
      canCompose = false;
      await delayedRetry;
      expect(presigns, 0, reason: 'Compose revoked while rebind was pending');
      expect(controller.pending.single.isFailed, isTrue);
      final before = presigns;
      await controller.retry(controller.pending.single, chatId: 'chat');
      expect(await file.readAsBytes(), orderedEquals(bytes));
      if (strict) {
        expect(presigns, before + 1);
        expect(adapter.count, 1);
        expect(confirms, 1);
        expect(saves, 1);
        expect(adapter.bodies.last, orderedEquals(bytes));
        expect(controller.pending.single.isUploaded, isTrue);

        // Once PUT has started, its result may be ambiguous even after a 500.
        // A later rotation receipt must not silently authorize a second PUT.
        final other = ChatAttachmentsController(service, GlobalCache(), client,
            authScope: scope, capabilities: caps, rotationReceipt: receipt);
        expect(other.add(attach), isTrue);
        await other.upload(attach, chatId: 'chat');
        expect(other.pending.single.isFailed, isTrue);
        expect(adapter.count, 2);
        final beforeSecondOwner = scope.capture()!;
        await client.auth.refreshSession();
        events.add(AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession));
        final afterSecondOwner = scope.capture()!;
        expect(caps.grant(SessionCapabilityMode.online,
            caps.beginAuthorization(afterSecondOwner)!), isTrue);
        receipt.record(beforeSecondOwner, afterSecondOwner, caps);
        final beforeAmbiguousRetry = presigns;
        await other.retry(other.pending.single, chatId: 'chat');
        expect(presigns, beforeAmbiguousRetry);
        expect(adapter.count, 2);
        expect(other.pending.single.isFailed, isTrue);
        expect(await file.readAsBytes(), orderedEquals(bytes));
        other.dispose();

        final blocked = ChatAttachmentsController(service, GlobalCache(), client,
            authScope: scope, capabilities: caps, rotationReceipt: receipt);
        expect(blocked.add(attach), isTrue);
        final beforeBlock = presigns;
        caps.block();
        await blocked.upload(attach, chatId: 'chat');
        expect(presigns, beforeBlock, reason: 'Explicit block fences dispatch');
        expect(blocked.pending, hasLength(1));
        expect(await file.readAsBytes(), orderedEquals(bytes));
        blocked.dispose();
      }

    } finally {
      await syncSub.cancel();
      await asyncSub.cancel();
      controller.dispose();
      receipt.dispose();
      caps.dispose();
      scope.dispose();
      await events.close();
      service.dispose();
      dio.close(force: true);
      await file.delete();
      await dir.delete();
      unawaited(client.dispose());
    }
  }, skip: !strict);
}
