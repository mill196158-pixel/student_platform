import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'visible attachment hides on denial and retries after fresh grant',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('chat-revoke-ui-')))!;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(links, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    var allowed = true;
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/pic.png';
    const uid = 'widget-user';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
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
            request: request, headers: {'content-type': 'application/json'}));
    await tester.runAsync(() => Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    addTearDown(() async {
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(links, null);
      for (var i = 0; i < 20 && await dir.exists(); i++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    await tester.runAsync(
        () => signInWithFileSession(Supabase.instance.client, uid, sid));
    final fileKey = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('$uid:$fileKey'));
    final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await tester.runAsync(() async {
      await data.parent.create(recursive: true);
      await data.writeAsBytes(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAOElEQVR4nO3OQQ3AMADEsDT8OW8U9utpihH4AA/fHC6QcTJOxsk4GSfjZJyM83YgSZIkSZIk+a8X4+QBFAcIezwAAAAASUVORK5CYII='));
      await File('${data.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AuthorizedFileImage(
      imageUrl: url,
      width: 40,
      height: 40,
      errorWidget: (_, __, ___) => const Text('revoked'),
    ))));
    Future<void> settleIo() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
    }

    await settleIo();
    expect(find.text('revoked'), findsNothing);
    final owner = ChatFileAccess.userId;
    final epoch = ChatFileAccess.generation;
    final binding = ChatFileAccess.currentSessionBinding;
    expect(
        ChatFileAccess.isViewerCurrent(url,
            user: owner, epoch: epoch, sessionBinding: binding),
        isTrue);

    // Let the initial background authorization finish before testing a new
    // response; otherwise resolve correctly joins the existing request.
    for (var i = 0; i < 10; i++) {
      await settleIo();
    }
    allowed = false;
    var done = false;
    unawaited(ChatFileAccess.resolve(url).then<void>((_) {
      done = true;
    }, onError: (Object _, StackTrace __) {
      done = true;
    }));
    for (var i = 0; i < 20 && !done; i++) {
      await settleIo();
    }
    expect(done, isTrue);
    await tester.pump();
    expect(find.text('revoked'), findsOneWidget);
    expect(
        ChatFileAccess.isViewerCurrent(url,
            user: owner, epoch: epoch, sessionBinding: binding),
        isFalse);
    expect(await tester.runAsync(() => data.exists()), isTrue);

    allowed = true;
    await tester.tap(find.text('revoked'));
    await settleIo();
    expect(find.text('revoked'), findsNothing);
    expect(
        ChatFileAccess.isViewerCurrent(url,
            user: owner, epoch: epoch, sessionBinding: binding),
        isTrue);
    await tester.pumpWidget(const SizedBox());
    await settleIo();
  });
}
