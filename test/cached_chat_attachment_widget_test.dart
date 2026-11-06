import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_attachment.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('source change, revoke and local document open stay offline', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('cached-widget-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    var requests = 0;
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
      httpClient: MockClient((_) async { requests++; throw const SocketException('offline'); }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    const uid = 'widget-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final session = Supabase.instance.client.auth.currentSession!;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    var service = DmChatService.cachedOnly(peerId: 'peer', initialChatId: 'chat', capabilities: caps,
      cacheReader: (_, __) async => throw StateError('not used'));
    expect(service.canReadCached, isTrue);
    ChatFile makeFile(String name, String mime, {bool deleted = false}) => ChatFile(
      id: name, chatId: 'chat', messageId: 'm', fileName: name, fileKey: name,
      fileUrl: 'https://studentsplatform.storage.yandexcloud.net/chats/test/$name',
      fileType: mime, fileSize: 3, uploadedBy: uid, uploadedAt: DateTime.utc(2026), isDeleted: deleted);
    final first = makeFile('first.png', 'image/png');
    final second = makeFile('second.png', 'image/png');
    final document = makeFile('document.pdf', 'application/pdf');
    final missingDocument = makeFile('missing.docx',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII=');
    final firstPng = Uint8List.fromList([...png, 1]);
    final secondPng = Uint8List.fromList([...png, 2]);
    Future<void> save(ChatFile item, List<int> bytes) async {
      final key = ChatFileAccess.keyFor(item.fileUrl)!;
      final file = File('${dir.path}/authorized_chat_files/$uid/${sha256.convert(utf8.encode('$uid:$key'))}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    }
    await tester.runAsync(() async {
      await save(first, png);
      await save(second, png);
      await save(document, [7, 8, 9]);
    });
    final gate = Completer<void>();
    Future<void> mount(ChatFile file, {Future<void> Function()? beforeRead,
        Future<bool> Function(String)? open, bool actualRead = false,
        Future<Uint8List?> Function(ChatFile)? read}) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatAttachment(
        file: file, service: service, debugBeforeRead: beforeRead, debugOpen: open,
        debugRead: read ?? (actualRead ? null : (item) async => item.isImage
            ? (item.id == first.id ? firstPng : secondPng)
            : Uint8List.fromList([7, 8, 9]))))));
      await tester.pump();
    }
    await mount(first, beforeRead: () => gate.future);
    await mount(second);
    gate.complete();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Вложение: first.png'), findsNothing);
    final shown = tester.widget<Image>(find.byType(Image).first).image as MemoryImage;
    expect(shown.bytes, secondPng);
    await tester.tap(find.byType(Image).first);
    // A second tap before the overlay frame must not add another back entry.
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Назад'), findsOneWidget);
    expect(tester.widget<Material>(find.ancestor(
      of: find.byType(InteractiveViewer), matching: find.byType(Material)).first).color,
      Colors.white);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final viewerSize = tester.getSize(find.byType(InteractiveViewer));
    expect(viewerSize, tester.view.physicalSize / tester.view.devicePixelRatio);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatAttachment(
      file: makeFile('second.png', 'image/png', deleted: true), service: service))));
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(Image), findsNothing);
    final documentReadGate = Completer<void>();
    await mount(document, beforeRead: () => documentReadGate.future);
    tester.widget<AppFileCard>(find.byType(AppFileCard)).onTap!();
    await tester.pump();
    expect(find.text('Файл ещё читается.'), findsOneWidget);
    documentReadGate.complete();
    await tester.pump();
    ScaffoldMessenger.of(tester.element(find.byType(AppFileCard))).clearSnackBars();
    await tester.pumpAndSettle();
    final missingBytes = await tester.runAsync(() => ChatFileAccess.readCachedOnly(
        missingDocument.fileUrl, permit: () => service.canReadCached));
    expect(missingBytes, isNull);
    await mount(missingDocument, read: (_) async => missingBytes);
    await tester.pump();
    expect(find.byType(AppFileCard), findsOneWidget);
    tester.widget<AppFileCard>(find.byType(AppFileCard)).onTap!();
    await tester.pump();
    expect(find.text('Локальная копия недоступна.'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(AppFileCard))).clearSnackBars();
    await tester.pumpAndSettle();
    var opened = false;
    final actualDocumentRead = Completer<void>();
    await mount(document, read: (item) async {
      final bytes = await ChatFileAccess.readCachedOnly(item.fileUrl,
          permit: () => service.canReadCached);
      actualDocumentRead.complete();
      return bytes;
    }, open: (path) async {
      opened = true;
      expect(await File(path).readAsBytes(), [7, 8, 9]);
      return true;
    });
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(Image), findsNothing);
    for (var i = 0; i < 100 && !actualDocumentRead.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(actualDocumentRead.isCompleted, isTrue);
    await tester.pump();
    final button = tester.widget<AppFileCard>(find.byType(AppFileCard));
    await tester.runAsync(() async {
      button.onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(opened, isTrue);
    await mount(document, open: (_) async => false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.runAsync(() async {
      tester.widget<AppFileCard>(find.byType(AppFileCard)).onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Не удалось открыть сохранённый файл.'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(AppFileCard))).clearSnackBars();
    await tester.pumpAndSettle();
    final openEntered = Completer<void>();
    final openResult = Completer<bool>();
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(document, open: (_) async {
      openEntered.complete();
      return openResult.future;
    });
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.runAsync(() async {
      tester.widget<AppFileCard>(find.byType(AppFileCard)).onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(openEntered.isCompleted, isTrue);
    caps.block();
    openResult.complete(false);
    await tester.pump();
    expect(find.text('Не удалось открыть сохранённый файл.'), findsNothing);
    await service.dispose();
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    service = DmChatService.cachedOnly(peerId: 'peer', initialChatId: 'chat', capabilities: caps,
      cacheReader: (_, __) async => throw StateError('not used'));
    await mount(second, actualRead: true);
    for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final diskImage = tester.widget<Image>(find.byType(Image).first).image as MemoryImage;
    expect(diskImage.bytes, png);
    final revokedRead = Completer<void>();
    await mount(first, beforeRead: () => revokedRead.future);
    await mount(makeFile('first.png', 'image/png', deleted: true));
    revokedRead.complete();
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await mount(second);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isTrue);
    caps.block();
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(navigator.canPop(), isFalse);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await service.dispose();
    caps.dispose();
    scope.dispose();
    await tester.runAsync(() async {
      await events.close();
    });
    // Supabase is process-scoped in this standalone test. Its desktop app-links
    // mock does not finish dispose; the flutter test worker owns its lifetime.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), null);
    await tester.runAsync(() async {
      if (await dir.exists()) {
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await dir.resolveSymbolicLinks();
        if (!p.isWithin(root, resolved) || !p.basename(resolved).startsWith('cached-widget-')) {
          throw StateError('Unsafe test cleanup target');
        }
        await dir.delete(recursive: true);
      }
    });
  });
}
