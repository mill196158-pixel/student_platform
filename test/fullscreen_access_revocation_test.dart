import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['single', 'gallery', 'pdf']) {
    for (final trigger in ['denial', 'account switch']) {
      testWidgets(
          'fullscreen $kind hides content and disables actions after $trigger',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        final dir = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('viewer-revoke-test-')))!;
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        const links = MethodChannel('com.llfbandit.app_links/events');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => dir.path);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(links, (_) async => null);
        var allowed = true;
        const url =
            'https://studentsplatform.storage.yandexcloud.net/chats/test/pic.png';
        final transport = MockClient((request) async => allowed
            ? http.Response(
                jsonEncode({
                  'url': url,
                  'accessPolicyVersion': 1,
                  'cacheable': false,
                  'expiresIn': 60
                }),
                200,
                request: request,
                headers: {'content-type': 'application/json'})
            : http.Response(
                '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
                request: request,
                headers: {'content-type': 'application/json'}));
        await tester.runAsync(() => Supabase.initialize(
            url: 'https://example.test',
            publishableKey: 'test',
            httpClient: transport,
            authOptions:
                const FlutterAuthClientOptions(autoRefreshToken: false)));
        addTearDown(() async {
          await Supabase.instance.dispose();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(links, null);
          for (var attempt = 0; attempt < 10 && await dir.exists(); attempt++) {
            try {
              await dir.delete(recursive: true);
            } on FileSystemException {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
        });
        final uid = 'viewer-$kind-$trigger';
        await tester.runAsync(() => signInWithFileSession(
            Supabase.instance.client,
            uid,
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
        final fileKey = ChatFileAccess.keyFor(url)!;
        final digest = sha256.convert(utf8.encode('$uid:$fileKey'));
        final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
        await tester.runAsync(() async {
          await data.parent.create(recursive: true);
          await data.writeAsBytes(base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAOElEQVR4nO3OQQ3AMADEsDT8OW8U9utpihH4AA/fHC6QcTJOxsk4GSfjZJyM83YgSZIkSZIk+a8X4+QBFAcIezwAAAAASUVORK5CYII='));
          await File('${data.path}.grant').writeAsString(
              'chat-file-grant-v2:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
        });
        await tester.pumpWidget(MaterialApp(
            home: kind == 'single'
                ? const FullscreenImage(imageUrl: url)
                : kind == 'gallery'
                    ? const FullscreenImage(
                        imageUrl: url, galleryUrls: [url, url])
                    : const FullscreenFileViewer(
                        fileUrl: url,
                        fileName: 'a.pdf',
                        fileSize: 0,
                        mimeType: 'application/pdf')));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          if (kind == 'pdf' ||
              find.byType(FullscreenImageSurface).evaluate().isNotEmpty) break;
        }
        if (kind != 'pdf')
          expect(find.byType(FullscreenImageSurface), findsWidgets);
        if (trigger == 'account switch') {
          await tester.runAsync(() => signInWithFileSession(
              Supabase.instance.client,
              'another-user',
              'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'));
        } else {
          allowed = false;
          var done = false;
          unawaited(ChatFileAccess.resolve(url).then<void>((_) {
            done = true;
          }, onError: (Object _, StackTrace __) {
            done = true;
          }));
          for (var i = 0; i < 50 && !done; i++) {
            await tester.pump(const Duration(milliseconds: 10));
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)));
          }
          expect(done, isTrue);
        }
        await tester.pump();
        expect(find.text('Вложение недоступно'), findsOneWidget);
        expect(await tester.runAsync(() => data.exists()), isTrue);
        final open = find.byWidgetPredicate((widget) =>
            widget is IconButton &&
            (widget.tooltip == 'Открыть' || widget.tooltip == 'Открыть файл'));
        expect(tester.widget<IconButton>(open).onPressed, isNull);
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(seconds: 1));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
        }
      });
    }
  }
}
