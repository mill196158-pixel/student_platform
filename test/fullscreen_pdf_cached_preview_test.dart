import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PDF viewer uses granted cached file without creating export',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pdf-cache-preview-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    var httpCalls = 0;
    final transport = MockClient((request) async {
      httpCalls++;
      return http.Response('offline', 503, request: request);
    });
    await tester.runAsync(() => Supabase.initialize(
          url: 'https://example.test',
          publishableKey: 'test',
          httpClient: transport,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        ));
    addTearDown(() async {
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(links, null);
      for (var i = 0; i < 10 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 100)); }
      }
    });
    const uid = 'cached-pdf-user';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/doc.pdf';
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client, uid, sid));
    final digest = sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final cached = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await tester.runAsync(() async {
      await cached.parent.create(recursive: true);
      await cached.writeAsString('%PDF-1.4\n%%EOF\n');
      await File('${cached.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    httpCalls = 0;
    await tester.pumpWidget(const MaterialApp(
      home: FullscreenFileViewer(fileUrl: url, fileName: 'doc.pdf',
          fileSize: 15, mimeType: 'application/pdf'),
    ));
    for (var i = 0; i < 100 && find.byType(PdfDocumentViewBuilder).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(find.byType(PdfDocumentViewBuilder), findsOneWidget);
    expect(await tester.runAsync(() => Directory('${dir.path}/chat_files').exists()), isFalse);
    expect(httpCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('account switch during cached-path lookup prevents preview',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pdf-cache-switch-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final started = Completer<void>();
    final release = Completer<String>();
    messenger.setMockMethodCallHandler(pathChannel, (_) async {
      if (!started.isCompleted) started.complete();
      return release.future;
    });
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final transport = MockClient((request) async => http.Response('offline', 503, request: request));
    await tester.runAsync(() => Supabase.initialize(
        url: 'https://example.test', publishableKey: 'test', httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    addTearDown(() async {
      if (!release.isCompleted) release.complete(dir.path);
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(links, null);
      for (var i = 0; i < 10 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 100)); }
      }
    });
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client,
        'preview-a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
    await tester.pumpWidget(const MaterialApp(home: FullscreenFileViewer(
        fileUrl: 'https://studentsplatform.storage.yandexcloud.net/chats/test/doc.pdf',
        fileName: 'doc.pdf', fileSize: 1, mimeType: 'application/pdf')));
    await tester.runAsync(() => started.future);
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client,
        'preview-b', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'));
    release.complete(dir.path);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(find.text('Вложение недоступно'), findsOneWidget);
    expect(find.byType(PdfDocumentViewBuilder), findsNothing);
    expect(await tester.runAsync(() => Directory('${dir.path}/chat_files').exists()), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('same viewer state never presents an earlier PDF after URL changes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pdf-cache-rebind-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final transport = MockClient((request) async => http.Response('offline', 503, request: request));
    await tester.runAsync(() => Supabase.initialize(
        url: 'https://example.test', publishableKey: 'test', httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    final firstLookup = Completer<String>();
    final firstStarted = Completer<void>();
    var pathCalls = 0;
    addTearDown(() async {
      if (!firstLookup.isCompleted) firstLookup.complete(dir.path);
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(links, null);
      for (var i = 0; i < 10 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 100)); }
      }
    });
    const uid = 'pdf-rebind-user';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const urlA = 'https://studentsplatform.storage.yandexcloud.net/chats/test/a.pdf';
    const urlB = 'https://studentsplatform.storage.yandexcloud.net/chats/test/b.pdf';
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client, uid, sid));
    String filePath(String url) => '${dir.path}/authorized_chat_files/$uid/'
        '${sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'))}';
    await tester.runAsync(() async {
      for (final url in [urlA, urlB]) {
        final file = File(filePath(url));
        await file.parent.create(recursive: true);
        await file.writeAsString('%PDF-1.4\n%%EOF\n');
        await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
      }
    });
    messenger.setMockMethodCallHandler(pathChannel, (_) async {
      if (pathCalls++ == 0) {
        firstStarted.complete();
        return firstLookup.future;
      }
      return dir.path;
    });
    Widget screen(String url) => MaterialApp(home: FullscreenFileViewer(
      key: const ValueKey('viewer'), fileUrl: url, fileName: 'doc.pdf',
      fileSize: 15, mimeType: 'application/pdf'));
    await tester.pumpWidget(screen(urlA));
    await tester.runAsync(() => firstStarted.future);
    await tester.pumpWidget(screen(urlB));
    // Both lookups share the owner queue, so B waits for A's delayed lookup.
    expect(find.byType(PdfDocumentViewBuilder), findsNothing);
    firstLookup.complete(dir.path);
    for (var i = 0; i < 100 && find.byType(PdfDocumentViewBuilder).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(find.byType(PdfDocumentViewBuilder), findsOneWidget);
    var ref = tester.widget<PdfDocumentViewBuilder>(find.byType(PdfDocumentViewBuilder)).documentRef;
    expect((ref as PdfDocumentRefFile).file, filePath(urlB));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    ref = tester.widget<PdfDocumentViewBuilder>(find.byType(PdfDocumentViewBuilder)).documentRef;
    expect((ref as PdfDocumentRefFile).file, filePath(urlB));
    expect(await tester.runAsync(() => Directory('${dir.path}/chat_files').exists()), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing viewer source prevents in-flight old export publication',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pdf-cache-export-rebind-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final transport = MockClient((request) async => http.Response('offline', 503, request: request));
    await tester.runAsync(() => Supabase.initialize(
        url: 'https://example.test', publishableKey: 'test', httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    final started = Completer<void>();
    final release = Completer<http.Response>();
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async {
      if (!started.isCompleted) started.complete();
      return release.future;
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete(http.Response('%PDF-1.4\n%%EOF\n', 200));
      ChatFileAccess.debugHttpClientFactory = null;
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(links, null);
      for (var i = 0; i < 10 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 100)); }
      }
    });
    const uid = 'pdf-export-user';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const urlA = 'https://example.test/a.pdf';
    const urlB = 'https://studentsplatform.storage.yandexcloud.net/chats/test/b.pdf';
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client, uid, sid));
    final digestB = sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(urlB)}'));
    final cachedB = File('${dir.path}/authorized_chat_files/$uid/$digestB');
    await tester.runAsync(() async {
      await cachedB.parent.create(recursive: true);
      await cachedB.writeAsString('%PDF-1.4\n%%EOF\n');
      await File('${cachedB.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    });
    Widget screen(String url, String name) => MaterialApp(home: FullscreenFileViewer(
      key: const ValueKey('viewer'), fileUrl: url, fileName: name,
      fileSize: 15, mimeType: 'application/pdf'));
    await tester.pumpWidget(screen(urlA, 'a.pdf'));
    for (var i = 0; i < 100 && !started.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(started.isCompleted, isTrue);
    await tester.pumpWidget(screen(urlB, 'b.pdf'));
    release.complete(http.Response('%PDF-1.4\n%%EOF\n', 200));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    final digestA = sha1.convert(utf8.encode('$uid:$urlA'));
    expect(await tester.runAsync(() => File('${dir.path}/chat_files/${digestA}_a.pdf').exists()), isFalse);
    expect(find.byType(PdfDocumentViewBuilder), findsOneWidget);
    final ref = tester.widget<PdfDocumentViewBuilder>(find.byType(PdfDocumentViewBuilder)).documentRef;
    expect((ref as PdfDocumentRefFile).file, cachedB.path);
    await tester.pumpWidget(const SizedBox());
  });
}
