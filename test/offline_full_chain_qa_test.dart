import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/navigation/cached_team_chat_directory.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;
import 'auth_session_scope_test.dart' show fakeSession;

class _Home implements CachedHomeScheduleReader {
  _Home(this.caps);
  final SessionCapabilities caps;
  @override
  Listenable get accessChanges => caps;
  @override
  bool get canRead => caps.capture(SessionCapability.cachedRead) != null;
  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
        profile: const HomeUserProfile(id: 'qa-owner', name: 'Студент QA', groupName: 'Группа'),
        scheduleDate: DateTime.now(), todayLessons: const [], assignments: const [],
        news: const [], scheduleStatus: 'Сохранённое расписание');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('QA startup to SQLite DM and cached media without Supabase HTTP', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('ru');
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('offline_chain_qa_')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    var calls = 0;
    await tester.runAsync(() => Supabase.initialize(
      url: 'https://example.invalid', publishableKey: 'qa',
      httpClient: MockClient((_) async { calls++; throw const SocketException('offline'); }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false)));
    const uid = 'qa-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client, uid, sid));
    var session = Supabase.instance.client.auth.currentSession!;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final now = DateTime.now().toUtc();
    var binding = OfflineSessionBinding(issuer: 'https://example.invalid/auth/v1',
      userId: uid, sessionId: sid, notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    var db = (await tester.runAsync(() => openProjectChatServerDatabase(
        '${dir.path}/chats.sqlite', factory: databaseFactoryFfi)))!;
    ProjectChatServerCache makeCache() => ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://example.invalid');
    var cache = makeCache();
    ChatFile file(String name, String mime) => ChatFile(id: name, chatId: 'chat',
      messageId: 'message', fileName: name, fileKey: name,
      fileUrl: 'https://studentsplatform.storage.yandexcloud.net/chats/test/$name',
      fileType: mime, fileSize: 3, uploadedBy: uid, uploadedAt: now);
    final png = file('qa.png', 'image/png'), pdf = file('qa.pdf', 'application/pdf');
    final imageBytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII=');
    await tester.runAsync(() async {
      for (final item in [png, pdf]) {
        final key = ChatFileAccess.keyFor(item.fileUrl)!;
        final f = File('${dir.path}/authorized_chat_files/$uid/${sha256.convert(utf8.encode('$uid:$key'))}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(item == png ? imageBytes : [37, 80, 68, 70]);
        await File('${f.path}.grant').writeAsString('chat-file-grant-v2:$sid');
      }
      final summary = (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
      expect(await cache.saveSummaries(summary, [{
        'team': {'id': '', 'name': 'Peer', 'teacher': '', 'groupCode': '', 'icon': ''},
        'title': 'Локальный чат QA', 'chatId': 'chat', 'isDm': true, 'peerId': 'peer',
        'avatarUrl': 'https://example.invalid/avatar.png',
        'unread': 0, 'pinned': false, 'muted': false,
      }, {
        'team': {'id': 'team', 'name': 'Предмет QA', 'teacher': '', 'groupCode': 'Группа',
          'icon': '', 'kind': 'subject'},
        'title': 'Командный чат QA', 'chatId': 'team-chat', 'isDm': false,
        'unread': 0, 'pinned': false, 'muted': false,
      }]), isTrue);
      final ticket = (await cache.begin('chat'))!;
      expect(await cache.saveServerPage(ticket, [Message(id: 'message', chatId: 'chat',
        authorId: uid, authorLogin: uid, authorName: 'QA', text: 'Локальное сообщение QA',
        at: now, attachments: [png, pdf])], hasMore: false), isTrue);
      final teamTicket = (await cache.begin('team-chat'))!;
      expect(await cache.saveServerPage(teamTicket, [Message(id: 'team-message',
        chatId: 'team-chat', authorId: uid, authorLogin: uid, authorName: 'QA',
        text: 'Сообщение команды QA', at: now), Message(id: 'hidden-card',
        chatId: 'team-chat', authorId: uid, authorLogin: uid, authorName: 'QA',
        text: '{"card":"collection","collection_id":"hidden"}',
        at: now.add(const Duration(days: 1)))], hasMore: false), isTrue);
      await db.close();
      db = await openProjectChatServerDatabase('${dir.path}/chats.sqlite', factory: databaseFactoryFfi);
      cache = makeCache();
    });
    final reader = _Home(caps);
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(path: '/splash', builder: (_, __) => SplashScreen(qaAdmission: () async {
        caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
        return OfflineStartupResult.cacheOnly;
      })),
      GoRoute(path: '/home', builder: (_, __) => NavigationScreen(cachedReader: reader,
        cachedInfo: (_) => CachedTeamChatDirectory(store: cache, capabilities: caps, subjectsOnly: true),
        cachedLearning: (_) => CachedTeamChatDirectory(store: cache, capabilities: caps, subjectsOnly: false),
        cachedProfile: (_) => ProfileScreen(cachedReader: reader, cachedChats: cache, cachedCapabilities: caps))),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.textContaining('Студент QA'), findsOneWidget);
    for (final tab in ['База', 'Обучение']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      for (var i = 0; i < 100 && find.text('Предмет QA').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Предмет QA'), findsOneWidget);
      await tester.tap(find.text('Предмет QA'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 100 && find.text('Сообщение команды QA').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Сообщение команды QA'), findsOneWidget);
      expect(find.textContaining('hidden'), findsNothing);
      expect(find.text('Сбор'), findsNothing);
      if (tab == 'База') {
        caps.block();
        await tester.pump();
        await tester.pump();
        expect(find.text('Сообщение команды QA'), findsNothing);
        expect(find.byType(TeamDetailsScreen), findsNothing);
        caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
        await tester.pumpAndSettle();
      } else {
        await tester.tap(find.byTooltip('Назад').last);
        await tester.pumpAndSettle();
      }
    }
    await tester.tap(find.text('Профиль').last);
    await tester.pumpAndSettle();
    tester.widget<StudentProfileScreenPreview>(find.byType(StudentProfileScreenPreview)).onMessagesTap!();
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && find.text('Локальный чат QA').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(MyChatsScreen), findsOneWidget);
    expect(tester.widgetList<Image>(find.byType(Image)).where((i) => i.image is NetworkImage), isEmpty);
    expect(tester.widgetList<CircleAvatar>(find.byType(CircleAvatar))
        .where((avatar) => avatar.backgroundImage is NetworkImage || avatar.foregroundImage is NetworkImage), isEmpty);
    await tester.tap(find.text('Локальный чат QA'));
    await tester.pumpAndSettle();
    bool mediaReady() => tester.widgetList<Image>(find.byType(Image)).any(
        (image) => image.image is MemoryImage &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)) &&
        tester.widgetList<AppFileCard>(find.byType(AppFileCard))
            .any((card) => card.fileName == 'qa.pdf' && card.onTap != null);
    for (var i = 0; i < 100 && !mediaReady(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(UnifiedChatScreen), findsOneWidget);
    expect(find.text('Локальное сообщение QA'), findsOneWidget);
    expect(find.text('qa.pdf'), findsOneWidget);
    expect(mediaReady(), isTrue);
    expect(tester.widgetList<Image>(find.byType(Image))
        .where((image) => image.image is MemoryImage &&
            (image.image as MemoryImage).bytes.length == imageBytes.length &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)), isNotEmpty);
    expect(calls, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Командный чат QA'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && find.text('Сообщение команды QA').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Сообщение команды QA'), findsOneWidget);
    await tester.runAsync(() async {
      final originalBinding = binding;
      binding = OfflineSessionBinding(issuer: 'https://example.invalid/auth/v1',
        userId: uid, sessionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        notBefore: originalBinding.notBefore, expiresAt: originalBinding.expiresAt);
      expect(await cache.read('team-chat', caps), isNull);
      expect(await cache.readSummaries(caps), isNull);
      binding = originalBinding;
      final foreignBinding = OfflineSessionBinding(issuer: 'https://other.invalid/auth/v1',
        userId: uid, sessionId: sid, notBefore: binding.notBefore, expiresAt: binding.expiresAt);
      final foreign = ProjectChatServerCache(db: db, scope: scope,
        currentBinding: () => foreignBinding, project: 'https://other.invalid');
      expect(await foreign.read('team-chat', caps), isNull);
      expect(await foreign.readSummaries(caps), isNull);
    });
    expect(calls, 0);
    await tester.tap(find.byTooltip('Назад').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Локальный чат QA'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && !mediaReady(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Локальное сообщение QA'), findsOneWidget);
    expect(find.text('qa.pdf'), findsOneWidget);
    expect(mediaReady(), isTrue);
    session = fakeSession('other-owner');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(find.text('Локальное сообщение QA'), findsNothing);
    expect(find.text('Сообщение команды QA'), findsNothing);
    expect(find.text('qa.pdf'), findsNothing);
    expect(tester.widgetList<Image>(find.byType(Image))
        .where((image) => image.image is MemoryImage &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose(); caps.dispose(); scope.dispose(); await events.close();
    await tester.runAsync(() async {
      await db.close();
      await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final path = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, path) || !p.basename(path).startsWith('offline_chain_qa_')) {
        throw StateError('Unsafe QA path');
      }
      await dir.delete(recursive: true);
    });
  });
}
