import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/chat_image_aspect_cache.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  testWidgets(
      'real image decode remembers dimensions when the widget is reopened',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final dir = await tester
        .runAsync(() => Directory.systemTemp.createTemp('image-geometry-'));
    messenger.setMockMethodCallHandler(paths, (_) async => dir!.path);
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/reopen.png';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final client = MockClient((request) async => http.Response(
        jsonEncode({'url': url, 'cacheable': true, 'accessPolicyVersion': 1,
          'expiresIn': 60}), 200,
        request: request, headers: {'content-type': 'application/json'}));
    await tester.runAsync(() async {
      await Supabase.initialize(
          url: 'https://example.test',
          publishableKey: 'test',
          httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await signInWithFileSession(Supabase.instance.client, 'geometry-reopen', sid);
      final digest = sha256.convert(
          utf8.encode('geometry-reopen:${ChatFileAccess.keyFor(url)}'));
      final file =
          File('${dir!.path}/authorized_chat_files/geometry-reopen/$digest');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
          await File('assets/icons/launcher_icon.png').readAsBytes());
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
      expect(ChatFileAccess.currentSessionBinding, sid);
      expect(await ChatFileAccess.readBytes(url), isNotEmpty);
    });
    Widget screen() => const MaterialApp(
        home: Scaffold(
            body: Center(
                child: AppNetworkImagePreview(
                    imageUrl: url, fileName: 'reopen.png', maxWidth: 300))));
    await tester.pumpWidget(screen());
    for (var i = 0;
        i < 50 &&
            ChatImageAspectCache.instance.read(
                    user: 'geometry-reopen',
                    epoch: ChatFileAccess.generation,
                    url: url) ==
                null;
        i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
    }
    expect(
        ChatImageAspectCache.instance.read(
            user: 'geometry-reopen',
            epoch: ChatFileAccess.generation,
            url: url),
        1);
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir!.resolveSymbolicLinks();
      if (!p.isWithin(root, target) || !p.basename(target).startsWith('image-geometry-')) {
        throw StateError('Unsafe geometry test directory');
      }
      await dir.delete(recursive: true);
    });
    messenger.setMockMethodCallHandler(links, null);
    messenger.setMockMethodCallHandler(paths, null);
  });

  testWidgets('remembered dimensions apply immediately while access is checked',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const appLinks = MethodChannel('com.llfbandit.app_links/events');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('image-geometry-'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appLinks, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => dir!.path);
    final pending = Completer<http.Response>();
    var requests = 0;
    final client = MockClient((request) {
      if (request.url.path.endsWith('/chat-file-access')) {
        requests++;
        return pending.future;
      }
      return Future.value(http.Response('{}', 404, request: request));
    });
    await tester.runAsync(() async {
      await Supabase.initialize(
          url: 'https://example.test',
          publishableKey: 'test',
          httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      await signInWithFileSession(Supabase.instance.client, 'geometry-user',
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/geometry.png';
      final digest = sha256.convert(utf8.encode('geometry-user:${ChatFileAccess.keyFor(url)}'));
      final file = File('${dir!.path}/authorized_chat_files/geometry-user/$digest');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(await File('assets/icons/launcher_icon.png').readAsBytes());
    });
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/geometry.png';
    ChatImageAspectCache.instance.remember(
        user: 'geometry-user',
        epoch: ChatFileAccess.generation,
        url: url,
        ratio: 1);
    Widget screen() => const MaterialApp(
        home: Scaffold(
            body: Center(
                child: AppNetworkImagePreview(
                    imageUrl: url, fileName: 'geometry.png', maxWidth: 300))));
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    expect(find.text('Загрузка...'), findsOneWidget);
    for (var i = 0; i < 100 && requests == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(requests, 1, reason: 'visible image must still verify access');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen());
    await tester.pump();
    expect(tester.getSize(find.byType(AppNetworkImagePreview)),
        const Size(245, 245));
    pending.complete(http.Response(jsonEncode({'url': url, 'cacheable': true,
      'accessPolicyVersion': 1, 'expiresIn': 60}), 200,
        headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 100 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir!.resolveSymbolicLinks();
      if (!p.isWithin(root, target) || !p.basename(target).startsWith('image-geometry-')) {
        throw StateError('Unsafe geometry test directory');
      }
      await dir.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appLinks, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
  });
}
