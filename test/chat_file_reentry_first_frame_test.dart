import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('previously decoded authorized image reopens on first frame and late denial hides both viewers', (tester) async {
    expect(ChatFileAccess.decodedImageExperimentEnabled, isFalse);
    ChatFileAccess.debugDecodedImageExperiment = true;
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('image_reentry_qa_')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    const uid = 'qa-image-owner', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/image.png';
    final delayed = Completer<http.Response>();
    var calls = 0;
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.invalid', publishableKey: 'qa',
      httpClient: MockClient((_) { calls++; return delayed.future; }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false)));
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client, uid, sid));
    final digest = sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAOElEQVR4nO3OQQ3AMADEsDT8OW8U9utpihH4AA/fHC6QcTJOxsk4GSfjZJyM83YgSZIkSZIk+a8X4+QBFAcIezwAAAAASUVORK5CYII=');
    await tester.runAsync(() async {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png);
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    Widget app({required int viewers}) => MaterialApp(home: Scaffold(body: Row(children: [
      for (var i = 0; i < viewers; i++) AuthorizedFileImage(imageUrl: url, width: 40, height: 40,
        placeholder: (_, __) => const Text('loading-image'),
        errorWidget: (_, __, error) => Text('denied-image:${error.runtimeType}')),
    ])));
    await tester.pumpWidget(app(viewers: 1));
    for (var i = 0; i < 150 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byType(RawImage), findsOneWidget,
        reason: 'loading=${find.text('loading-image').evaluate().length}, errors=${tester.widgetList<Text>(find.textContaining('denied-image')).map((x) => x.data).toList()}, checks=$calls');
    expect(calls, 1);
    final epoch = ChatFileAccess.generation;
    final client = ChatFileAccess.currentClientIdentity;
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch,
      sessionBinding: sid, clientIdentity: client), isTrue);
    expect(ChatFileAccess.canShowDecodedImage(url, user: 'other', epoch: epoch,
      sessionBinding: sid, clientIdentity: client), isFalse);
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch + 1,
      sessionBinding: sid, clientIdentity: client), isFalse);
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch,
      sessionBinding: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', clientIdentity: client), isFalse);
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch,
      sessionBinding: sid, clientIdentity: Object()), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(viewers: 2));
    // No subsequent pump/network response: both decoded images are present in
    // the first built frame when their prior receipt and decoded pixels exist.
    expect(find.text('loading-image'), findsNothing);
    expect(find.byType(RawImage), findsNWidgets(2));
    delayed.complete(http.Response('{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
      headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 150 && find.textContaining('denied-image').evaluate().length != 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.textContaining('denied-image'), findsNWidgets(2));
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch,
      sessionBinding: sid, clientIdentity: client), isFalse);
    expect(await tester.runAsync(file.exists), isTrue);
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, target) || !p.basename(target).startsWith('image_reentry_qa_')) {
        throw StateError('Unsafe QA directory');
      }
      for (var i = 0; i < 40 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 50)); }
      }
      expect(await dir.exists(), isFalse);
    });
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(links, null);
    ChatFileAccess.debugDecodedImageExperiment = false;
  });

  testWidgets('logout fence immediately invalidates process-local image permission', (tester) async {
    ChatFileAccess.debugDecodedImageExperiment = true;
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('image_reentry_qa_')))!;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    const uid = 'qa-logout-owner', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/logout.png';
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.invalid', publishableKey: 'qa',
      httpClient: MockClient((_) async => throw const SocketException('offline')),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false)));
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client, uid, sid));
    final digest = sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await tester.runAsync(() async {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
      await ChatFileAccess.authorize(url);
    });
    final epoch = ChatFileAccess.generation, client = ChatFileAccess.currentClientIdentity;
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch,
      sessionBinding: sid, clientIdentity: client), isTrue);
    ChatFileAccess.fenceForLogout();
    expect(ChatFileAccess.canShowDecodedImage(url, user: uid, epoch: epoch,
      sessionBinding: sid, clientIdentity: client), isFalse);
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.runAsync(() async {
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, target) || !p.basename(target).startsWith('image_reentry_qa_')) {
        throw StateError('Unsafe QA directory');
      }
      for (var i = 0; i < 40 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 50)); }
      }
      expect(await dir.exists(), isFalse);
    });
    ChatFileAccess.debugResetProcessMemory();
    ChatFileAccess.debugDecodedImageExperiment = false;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(links, null);
  });
}
