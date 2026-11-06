import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_attachment.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_message_bubble.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/scoped_forward_author_resolver.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'mock online RPC and PDF become same scoped offline forward and author',
      (tester) async {
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('forward_online_offline_qa_')))!;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    messenger.setMockMethodCallHandler(links, (_) async => null);
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/qa/same.pdf';
    const uid = 'qa-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const bytes = <int>[37, 80, 68, 70, 1, 2, 3];
    var offline = false, onlineRequests = 0, offlineRequests = 0;
    final serverRows = [
      {
        'id': 'source',
        'chat_id': 'chat',
        'author_id': 'author',
        'author_login': 'login',
        'author_name': 'Настоящий автор',
        'text': 'Студент',
        'type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
        'has_more': false,
        'attachments': [{
          'id': 'file', 'chat_id': 'chat', 'message_id': 'source',
          'file_name': 'same.pdf', 'file_key': 'chats/qa/same.pdf',
          'file_url': url, 'file_type': 'application/pdf', 'file_size': 7,
          'is_deleted': false
        }]
      },
      {
        'id': 'forward',
        'chat_id': 'chat',
        'author_id': 'owner',
        'author_login': 'owner',
        'author_name': 'Owner',
        'text': '', 'content': jsonEncode({'from_chat_id': 'chat', 'items': [{
          'id': 'source', 'author_id': 'author', 'author_name': 'Студент',
          'created_at': '2026-01-01T00:00:00Z', 'text': 'Студент',
          'attachments': [{'id': 'file', 'url': url, 'name': 'same.pdf',
            'mime': 'application/pdf', 'size': 7}]
        }]}),
        'type': 'forward',
        'created_at': '2026-01-02T00:00:00Z',
        'has_more': false,
        'attachments': []
      },
      {
        'id': 'forged', 'chat_id': 'chat', 'author_id': 'owner',
        'author_login': 'owner', 'author_name': 'Owner', 'type': 'forward',
        'created_at': '2026-01-03T00:00:00Z', 'has_more': false,
        'attachments': [],
        'text': '', 'content': jsonEncode({'from_chat_id': 'chat', 'items': [{
          'id': 'source', 'author_id': 'forged-author', 'author_name': 'Студент',
          'author_name_verified': true, 'created_at': '2026-01-01T00:00:00Z',
          'text': 'Студент', 'attachments': []
        }]})
      }
    ];
    Future<http.Response> handle(http.Request request) async {
      if (offline) {
        offlineRequests++;
        throw const SocketException('offline');
      }
      onlineRequests++;
      if (request.url.path.endsWith('/get_chat_messages_page')) {
        return http.Response(jsonEncode(serverRows), 200,
            request: request, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.contains('/functions/v1/')) {
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
      }
      throw StateError('Unexpected test request: ${request.url.path}');
    }

    await tester.runAsync(() => Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: MockClient(handle),
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async {
          if (offline) {
            offlineRequests++;
            throw const SocketException('offline');
          }
          onlineRequests++;
          return http.Response.bytes(bytes, 200, request: request);
        });
    final session = Supabase.instance.client.auth.currentSession!;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(
        issuer: 'https://example.test/auth/v1',
        userId: uid,
        sessionId: sid,
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    final saved = await tester.runAsync(() async {
      var db = await openProjectChatServerDatabase('${dir.path}/chat.sqlite',
          factory: databaseFactoryFfi);
      ProjectChatServerCache cache() => ProjectChatServerCache(
          db: db,
          scope: scope,
          currentBinding: () => binding,
          project: 'https://example.test');
      var store = cache();
      final ticket = (await store.begin('chat'))!;
      final page =
          await SupabaseLearningRepository(client: Supabase.instance.client)
              .loadConfirmedChatPage('chat');
      expect(
          await store.saveServerPage(ticket, page.messages,
              hasMore: page.hasMore),
          true);
      expect(await ChatFileAccess.readBytes(url), bytes);
      await db.close();
      db = await openProjectChatServerDatabase('${dir.path}/chat.sqlite',
          factory: databaseFactoryFfi);
      store = cache();
      return (db, store);
    });
    expect(saved, isNotNull);
    expect(onlineRequests, greaterThan(0));
    offline = true;
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    final page = await tester.runAsync(() => saved!.$2.read('chat', caps));
    expect(page, isNotNull);
    final message = page!.firstWhere((m) => m.id == 'forward');
    expect(message.forward, isNotNull);
    expect(message.attachments, isEmpty);
    expect(page.firstWhere((m) => m.id == 'source').attachments!.single.deletionVerified, true);
    final service = DmChatService.cachedOnly(
        peerId: '',
        initialChatId: 'chat',
        capabilities: caps,
        cacheReader: (_, __) async => throw StateError('not used'));
    var opened = false;
    final done = Completer<void>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CachedChatMessageBubble(
                message: message,
                service: service,
                showAuthor: false,
                authorResolver: ScopedForwardAuthorResolver(
                    store: saved!.$2, capabilities: caps),
                debugForwardAttachmentBuilder: (file) => CachedChatAttachment(
                    file: file,
                    service: service,
                    debugRead: (file) async {
                      final result = await ChatFileAccess.readCachedOnly(
                          file.fileUrl,
                          permit: () => service.canReadCached);
                      expect(result, bytes);
                      if (!done.isCompleted) done.complete();
                      return result;
                    },
                    debugOpen: (path) async {
                      opened = true;
                      expect(await File(path).readAsBytes(), bytes);
                      return true;
                    })))));
    for (var i = 0;
        i < 150 &&
            (!done.isCompleted ||
                find
                    .textContaining('Настоящий автор: Студент')
                    .evaluate()
                    .isEmpty);
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(done.isCompleted, true);
    expect(find.textContaining('Настоящий автор: Студент'), findsOneWidget);
    expect(find.byType(AppFileCard), findsOneWidget);
    await tester.pump();
    await tester.runAsync(() async {
      tester.widget<AppFileCard>(find.byType(AppFileCard)).onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 100 && !opened; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(opened, true);
    expect(offlineRequests, 0);
    final sourceFile = page.firstWhere((m) => m.id == 'source').attachments!.single;
    for (final conflicting in <List<ChatFile>>[
      [sourceFile.copyWith(fileUrl: '$url-other')],
      [sourceFile.copyWith(id: 'other')],
      [sourceFile, sourceFile],
      [sourceFile.copyWith(isDeleted: true)],
    ]) {
      var openedConflict = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatMessageBubble(
        message: message.copyWith(attachments: conflicting), service: service, showAuthor: false,
        authorResolver: ScopedForwardAuthorResolver(store: saved.$2, capabilities: caps),
        debugForwardAttachmentBuilder: (_) { openedConflict = true; return const SizedBox(); },
      ))));
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(openedConflict, false);
      expect(find.byType(AppFileCard), findsNothing);
    }
    expect(offlineRequests, 0);
    const team = Team(id: 'team', name: 'Test team', teacher: '', groupCode: '', icon: 'T');
    await tester.pumpWidget(MaterialApp(home: TeamDetailsScreen(team: team,
      cachedStore: saved.$2, cachedCapabilities: caps, cachedChatId: 'chat', initialTabIndex: 1)));
    for (var i = 0; i < 150 && (find.byType(AppFileCard).evaluate().isEmpty ||
        find.textContaining('Настоящий автор: Студент').evaluate().isEmpty); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(AppFileCard), findsNWidgets(2));
    expect(find.textContaining('Настоящий автор: Студент'), findsOneWidget);
    expect(find.textContaining('Студент (автор не подтверждён): Студент'), findsOneWidget);
    expect(offlineRequests, 0);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatMessageBubble(
      message: message, service: service, showAuthor: false,
      authorResolver: ScopedForwardAuthorResolver(store: saved.$2, capabilities: caps),
      debugGuardedAttachmentBuilder: (file, guard) => CachedChatAttachment(
        file: file, service: service, sourceIsCurrent: guard,
        sourceChanges: ProjectChatServerCache.snapshotChanges,
        debugRead: (_) async => Uint8List.fromList(bytes),
        debugOpen: (_) async { opened = true; return true; }),
    ))));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(AppFileCard), findsOneWidget);
    final oldTap = tester.widget<AppFileCard>(find.byType(AppFileCard)).onTap!;
    opened = false;
    final ticket = await tester.runAsync(() async {
      final pending = saved.$2.begin('chat');
      oldTap(); // Before the frame that removes the stale card.
      return await pending;
    });
    expect(opened, false);
    expect(ticket, isNotNull);
    late Completer<void> release;
    late Future<bool> writing;
    await tester.runAsync(() async {
      final started = Completer<void>();
      release = Completer<void>();
      saved.$2.debugBeforePageCommit = () async { started.complete(); await release.future; };
      writing = saved.$2.saveServerPage(ticket!, [
        for (final item in page)
          if (item.id == 'source') item.copyWith(attachments: [
            item.attachments!.single.copyWith(isDeleted: true)
          ]) else item,
      ], hasMore: false);
      await started.future.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
    expect(find.byType(AppFileCard), findsNothing);
    expect(await tester.runAsync(() async { release.complete(); return await writing; }), true);
    saved.$2.debugBeforePageCommit = null;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(AppFileCard), findsNothing);
    expect(offlineRequests, 0);
    final retryTicket = await tester.runAsync(() => saved.$2.begin('chat'));
    expect(retryTicket, isNotNull);
    saved.$2.debugBeforePageCommit = () async => throw StateError('rollback');
    await tester.runAsync(() async {
      await expectLater(saved.$2.saveServerPage(retryTicket!, page, hasMore: false),
          throwsStateError);
    });
    saved.$2.debugBeforePageCommit = null;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(AppFileCard), findsNothing);
    final freshTicket = await tester.runAsync(() => saved.$2.begin('chat'));
    expect(await tester.runAsync(() => saved.$2.saveServerPage(freshTicket!, page, hasMore: false)), true);
    for (var i = 0; i < 40 && find.byType(AppFileCard).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(AppFileCard), findsOneWidget);
    expect(offlineRequests, 0);
    caps.block();
    await tester.pump();
    expect(find.textContaining('Настоящий автор'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await service.dispose();
    caps.dispose();
    scope.dispose();
    await tester.runAsync(() async {
      await saved.$1.close();
      await events.close();
    });
    ChatFileAccess.debugHttpClientFactory = null;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(links, null);
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final actual = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, actual) ||
          !p.basename(actual).startsWith('forward_online_offline_qa_')) {
        throw StateError('Unsafe temporary directory');
      }
      await dir.delete(recursive: true);
    });
  });
}
