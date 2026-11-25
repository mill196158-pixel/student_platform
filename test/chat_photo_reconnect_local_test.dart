import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/file_message_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/multi_file_bubble.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _origin = 'http://127.0.0.1:55321';
const _storage = 'https://studentsplatform.storage.yandexcloud.net';

class _FixtureCache extends PathProviderPlatform {
  _FixtureCache(this.dir);
  final Directory dir;
  @override
  Future<String> getApplicationCachePath() async => dir.path;
}

class _RealSockets extends HttpOverrides {}

class _PendingPhoto extends AuthorizedFileImageProvider {
  _PendingPhoto(super.url);
  final result = Completer<AuthorizedFileImageProvider>();
  @override
  Future<AuthorizedFileImageProvider> obtainKey(
          ImageConfiguration configuration) =>
      result.future;
}

// Authenticate against local GoTrue. Only the two synthetic attachments are
// served by the controllable signer so switching its connection is repeatable.
class _Transport extends http.BaseClient {
  final auth = IOClient(
      _RealSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final available = <String>{};
  final requests = <String>[];
  String? token;
  bool online = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _origin)
      throw StateError('Expected local backend');
    if (request.url.path == '/auth/v1/token') return auth.send(request);
    if (request.url.path != '/functions/v1/chat-file-access' ||
        request.method != 'POST' ||
        token == null ||
        request.headers['Authorization'] != 'Bearer $token') {
      throw StateError('Unexpected local fixture request');
    }
    final body = jsonDecode(await request.finalize().bytesToString()) as Map;
    if (body['action'] != 'resolve') throw StateError('Expected resolve');
    final key = body['key'] as String;
    requests.add(key);
    if (!online || !available.contains(key))
      throw const SocketException('offline');
    final bytes = utf8.encode(jsonEncode({
      'url': '$_storage/$key',
      'accessPolicyVersion': 1,
      'cacheable': true,
      'expiresIn': 60
    }));
    return http.StreamedResponse(Stream.value(bytes), 200,
        request: request, headers: {'content-type': 'application/json'});
  }

  @override
  void close() => auth.close();
}

void main() {
  if (Platform.environment.containsKey('STUDENT_ATTACHMENT_LOCAL_CONFIG')) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      'late offline errors reach the current photo and drain after leaving',
      (tester) async {
    final first = _PendingPhoto('$_storage/chats/test/first.png');
    final second = _PendingPhoto('$_storage/chats/test/second.png');
    final reported = <Object>[];
    Widget photo(_PendingPhoto source) => MaterialApp(
        home: Image(
            image: source.forDisplay,
            errorBuilder: (_, error, __) {
              reported.add(error);
              return const Text('Ошибка загрузки');
            }));
    await tester.pumpWidget(photo(first));
    await tester.pumpWidget(photo(second));
    first.result.completeError(const SocketException('previous photo offline'));
    await tester.pump();
    expect(reported, isEmpty);
    expect(tester.takeException(), isNull);
    const offline = SocketException('current photo offline');
    second.result.completeError(offline);
    await tester.pumpAndSettle();
    expect(find.text('Ошибка загрузки'), findsOneWidget);
    expect(reported, isNotEmpty);
    expect(reported, everyElement(same(offline)));
    expect(tester.takeException(), isNull);
  });
  registerPhotoReconnectTest();
}

void registerPhotoReconnectTest() {
  final configFile = Platform.environment['STUDENT_ATTACHMENT_LOCAL_CONFIG'];
  testWidgets(
      'chat photo and gallery recover in place after interrupted validation',
      (tester) async {
    final config = jsonDecode(File(configFile!).readAsStringSync()) as Map;
    final transport = _Transport();
    final cache = Directory.systemTemp.createTempSync('chat-photo-reconnect-');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FixtureCache(cache);
    SharedPreferences.setMockInitialValues({});
    var blobRequests = 0;
    ChatFileAccess.debugHttpClientFactory = () => MockClient((_) async {
          blobRequests++;
          throw StateError('This scenario must use the original cached file');
        });
    addTearDown(() async {
      await Supabase.instance.dispose();
      transport.close();
      ChatFileAccess.debugHttpClientFactory = null;
      PathProviderPlatform.instance = oldPaths;
      cache.deleteSync(recursive: true);
    });
    await Supabase.initialize(
        url: _origin,
        publishableKey: config['anonKey'] as String,
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(
            detectSessionInUri: false,
            autoRefreshToken: false,
            localStorage: EmptyLocalStorage()));
    final auth = Supabase.instance.client.auth;
    await auth.signInWithPassword(
        email: config['email'] as String,
        password: config['password'] as String);
    final uid = auth.currentUser!.id;
    expect(uid == config['recipientId'], isTrue);
    transport.token = auth.currentSession!.accessToken;
    ChatFile pendingPhoto(String name, String encodedPng) {
      final bytes = base64Decode(encodedPng);
      final key = 'chats/test/$name.png';
      final digest = sha256.convert(utf8.encode('$uid:$key'));
      final data = File('${cache.path}/authorized_chat_files/$uid/$digest');
      data.parent.createSync(recursive: true);
      data.writeAsBytesSync(bytes);
      File('${data.path}.pending').writeAsStringSync(
          'chat-file-grant-v2:${ChatFileAccess.currentSessionBinding!}');
      return ChatFile(
          id: name,
          chatId: 'test',
          messageId: 'sample',
          fileName: '$name.png',
          fileKey: key,
          fileUrl: '$_storage/$key',
          fileType: 'image/png',
          fileSize: bytes.length,
          uploadedBy: uid,
          uploadedAt: DateTime(2026));
    }

    final first = pendingPhoto('first',
        'iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAOElEQVR4nO3OQQ3AMADEsDT8OW8U9utpihH4AA/fHC6QcTJOxsk4GSfjZJyM83YgSZIkSZIk+a8X4+QBFAcIezwAAAAASUVORK5CYII=');
    final second = pendingPhoto('second',
        'iVBORw0KGgoAAAANSUhEUgAAACgAAAAUCAYAAAD/Rn+7AAAANElEQVR4nO3OsREAIAwDsc/vvzOsQMPFhTWBBji8GRZIOAkn4SSchJNwEk7CuR2oqqriqwtTkQEUzSglOQAAAABJRU5ErkJggg==');
    ChatFileAccess.debugResetProcessMemory();
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(finder, findsWidgets);
    }

    final viewer = find.byType(FullscreenImage);
    final retry = find
        .descendant(of: viewer, matching: find.text('Повторить'))
        .hitTestable();
    final picture = find.descendant(
        of: viewer, matching: find.byType(FullscreenImageSurface));
    void expectDecodedPhoto(int height) {
      final image = tester.widget<RawImage>(find
          .descendant(
              of: picture.hitTestable(), matching: find.byType(RawImage))
          .first);
      expect(image.image!.width, 40);
      expect(image.image!.height, height);
    }

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FileMessageBubble(
                file: first,
                authorName: 'QA',
                isMe: false,
                showAvatar: false,
                time: '12:00',
                caption: 'Фото задания'))));
    await tester.tap(find.text('Фото задания'));
    await waitFor(find
        .descendant(
            of: viewer, matching: find.byIcon(Icons.broken_image_outlined))
        .hitTestable());
    expect(picture, findsNothing);
    expect(retry, findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'opening the offline photo');
    final beforeRetry = transport.requests.length;
    await tester.tap(retry);
    await tester.pump();
    await waitFor(retry);
    expect(transport.requests.length, greaterThan(beforeRetry));
    expect(picture, findsNothing);
    expect(tester.takeException(), isNull, reason: 'retrying offline');
    transport.available.add(first.fileKey);
    transport.online = true;
    await tester.tap(retry);
    await waitFor(picture.hitTestable());
    expectDecodedPhoto(40);
    expect(tester.takeException(), isNull,
        reason: 'recovering the first photo');
    await tester.tap(find.byTooltip('Закрыть'));
    for (var i = 0; i < 40 && viewer.evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(viewer, findsNothing);
    expect(tester.takeException(), isNull, reason: 'closing the single photo');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MultiFileBubble(
                files: [first, second],
                authorName: 'QA',
                isMe: false,
                time: '12:01',
                showAvatar: false))));
    final firstThumbnail =
        find.byType(AppNetworkImagePreview).first.hitTestable();
    await waitFor(firstThumbnail);
    await tester.tap(firstThumbnail);
    await waitFor(find.byType(PageView));
    await waitFor(picture.hitTestable());
    expectDecodedPhoto(40);
    expect(tester.takeException(), isNull, reason: 'entering the gallery');
    transport.online = false;
    await tester.drag(find.byType(PageView),
        Offset(-tester.getSize(find.byType(PageView)).width * .85, 0));
    await waitFor(retry);
    await tester.pumpAndSettle();
    expect(picture.hitTestable(), findsNothing);
    expect(tester.takeException(), isNull,
        reason: 'moving to the offline gallery page');
    final beforeGalleryRetry = transport.requests.length;
    transport.available.add(second.fileKey);
    transport.online = true;
    await tester.tap(retry);
    await waitFor(picture.hitTestable());
    expectDecodedPhoto(20);
    expect(
        transport.requests.skip(beforeGalleryRetry), contains(second.fileKey));
    expect(blobRequests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: configFile == null);
}
