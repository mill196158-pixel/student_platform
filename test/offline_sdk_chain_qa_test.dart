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
import 'package:http/http.dart' as http;
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
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/refresh_security_fence.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/core/offline_auth_error_receipt.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryAuthStorage extends LocalStorage {
  _MemoryAuthStorage(this.raw);
  String? raw;
  @override Future<void> initialize() async {}
  @override Future<bool> hasAccessToken() async => raw != null;
  @override Future<String?> accessToken() async => raw;
  @override Future<void> persistSession(String value) async { raw = value; }
  @override Future<void> removePersistedSession() async { raw = null; }
}

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
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real SDK admission to local DM and team screens', (tester) async {
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
    const uid = 'qa-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final now = DateTime.now().toUtc();
    const expired = bool.fromEnvironment('QA_EXPIRED', defaultValue: false);
    const failure = String.fromEnvironment('QA_FAILURE', defaultValue: '');
    const revokeWithGate = bool.fromEnvironment('QA_REVOKE_WITH_GATE', defaultValue: false);
    final tokenExpiry = expired ? now.subtract(const Duration(minutes: 1))
        : now.add(const Duration(hours: 1));
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
      'iss': 'https://example.invalid/auth/v1', 'sub': uid, 'session_id': sid,
      'role': 'authenticated', 'aud': 'authenticated',
      'iat': now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      'exp': tokenExpiry.millisecondsSinceEpoch ~/ 1000,
    })}.sig';
    final raw = jsonEncode({'access_token': token, 'refresh_token': 'synthetic',
      'token_type': 'bearer', 'expires_in': 3600,
      'expires_at': tokenExpiry.millisecondsSinceEpoch ~/ 1000,
      'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {},
        'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}});
    final saved = Session.fromJson(jsonDecode(raw))!;
    var binding = OfflineSessionBinding.fromSession(saved, 'https://example.invalid/auth/v1')!;
    final policyPath = '${dir.path}/policy.sqlite';
    var policyDb = (await tester.runAsync(() => openPolicyGrantDatabase(policyPath, factory: databaseFactoryFfi)))!;
    final priorEvents = StreamController<AuthState>.broadcast(sync: true);
    final priorScope = AuthSessionScope(currentSession: () => saved, authEvents: priorEvents.stream);
    priorEvents.add(AuthState(AuthChangeEvent.initialSession, saved));
    var policyStore = SqlitePolicyGrantStore(scope: priorScope, currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(policyDb));
    await tester.runAsync(() async {
      final ticket = (await policyStore.beginLiveCheck(priorScope.capture()!, binding))!;
      expect(await policyStore.saveAllowed(ticket, OfflinePolicyGrant(issuer: binding.issuer,
        userId: uid, sessionId: sid, checkedAt: now.subtract(const Duration(minutes: 2)),
        validUntil: now.add(const Duration(hours: 1)))), isTrue);
      policyStore.dispose(); priorScope.dispose(); await priorEvents.close(); await policyDb.close();
    });
    var calls = 0;
    final inner = MockClient((_) async {
      calls++;
      if (failure == '401' || failure == '403') {
        return http.Response('{"msg":"denied","error_code":"refresh_token_not_found"}',
            int.parse(failure), headers: {'content-type': 'application/json'});
      }
      if (failure == 'fence') throw RefreshSecurityFenceException();
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'), securityFence: fence);
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.invalid', publishableKey: 'qa',
      httpClient: gate, authOptions: FlutterAuthClientOptions(autoRefreshToken: true,
        localStorage: _MemoryAuthStorage(raw), detectSessionInUri: false)));
    final client = Supabase.instance.client;
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
      authEvents: client.auth.onAuthStateChange);
    await tester.runAsync(() => scope.ready);
    policyDb = (await tester.runAsync(() => openPolicyGrantDatabase(policyPath, factory: databaseFactoryFfi)))!;
    policyStore = SqlitePolicyGrantStore(scope: scope, currentBinding: () => binding,
      coordinator: SqlitePolicyGrantCoordinator(policyDb));
    final owner = scope.capture()!;
    final prior = await tester.runAsync(() => policyStore.capturePriorGrant(owner, binding));
    final revision = fence.revision;
    final admission = OfflineStartupAdmission(client: client, scope: scope, store: policyStore,
      gate: gate, monitor: monitor, fence: fence, owner: owner, binding: binding,
      prior: prior, fenceRevision: revision,
      policy: SettledPolicyTransport.forTesting(inner, Uri.parse('https://example.invalid')),
      backend: Uri.parse('https://example.invalid'), publicKey: 'qa');
    final caps = SessionCapabilities(scope);
    var db = (await tester.runAsync(() => openProjectChatServerDatabase(
        '${dir.path}/chats.sqlite', factory: databaseFactoryFfi)))!;
    ProjectChatServerCache makeCache() => ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://example.invalid');
    var cache = makeCache();
    ChatFile file(String name, String mime, {String chat = 'chat', String message = 'message'}) => ChatFile(id: name, chatId: chat,
      messageId: message, fileName: name, fileKey: name,
      fileUrl: 'https://studentsplatform.storage.yandexcloud.net/chats/test/$name',
      fileType: mime, fileSize: 3, uploadedBy: uid, uploadedAt: now);
    final png = file('qa.png', 'image/png'), pdf = file('qa.pdf', 'application/pdf');
    final teamPng = file('team.png', 'image/png', chat: 'team-chat', message: 'team-message');
    final imageBytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII=');
    await tester.runAsync(() async {
      for (final item in [png, pdf, teamPng]) {
        final key = ChatFileAccess.keyFor(item.fileUrl)!;
        final f = File('${dir.path}/authorized_chat_files/$uid/${sha256.convert(utf8.encode('$uid:$key'))}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(item == pdf ? [37, 80, 68, 70] : imageBytes);
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
        text: 'Сообщение команды QA', at: now, attachments: [teamPng])], hasMore: false), isTrue);
      await db.close();
      db = await openProjectChatServerDatabase('${dir.path}/chats.sqlite', factory: databaseFactoryFfi);
      cache = makeCache();
    });
    final reader = _Home(caps);
    final admissionResult = Completer<OfflineStartupResult>();
    var splashRequestedAdmission = false;
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(path: '/splash', builder: (_, __) => SplashScreen(qaAdmission: () {
        splashRequestedAdmission = true;
        return admissionResult.future;
      })),
      GoRoute(path: '/home', builder: (_, __) => NavigationScreen(cachedReader: reader,
        cachedProfile: (_) => ProfileScreen(cachedReader: reader, cachedChats: cache, cachedCapabilities: caps))),
      GoRoute(path: '/guest', builder: (_, __) => const Scaffold(body: Text('Доступ отклонён'))),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(splashRequestedAdmission, isTrue);
    await tester.runAsync(() async {
      gate.bind(CoordinatedRefreshClient.forTesting(inner, policyStore, Uri.parse('https://example.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence, monitor: monitor));
      final result = await admission.resolve(caps).timeout(const Duration(seconds: 35),
        onTimeout: () => throw StateError('Admission did not settle; transport attempts=$calls; '
          'socket settlement=${monitor.eligible}; fence unchanged=${fence.unchangedSince(revision)}'));
      expect(result, failure.isEmpty ? OfflineStartupResult.cacheOnly
          : isNot(OfflineStartupResult.cacheOnly));
      admissionResult.complete(result);
    });
    await tester.pumpAndSettle();
    if (failure.isNotEmpty) {
      expect(caps.capture(SessionCapability.cachedRead), isNull);
      final error = scope.lastAuthError;
      if (error != null) expect(OfflineAuthErrorReceipt.instance.accepts(error), isFalse);
      expect(find.text('Локальное сообщение QA'), findsNothing);
      expect(find.text('qa.pdf'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose(); caps.dispose(); policyStore.dispose(); scope.dispose();
      await tester.runAsync(() async {
        await db.close(); await policyDb.close(); await Supabase.instance.dispose();
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final path = await dir.resolveSymbolicLinks();
        if (!p.isWithin(root, path) || !p.basename(path).startsWith('offline_chain_qa_')) {
          throw StateError('Unsafe QA path');
        }
        await dir.delete(recursive: true);
      });
      return;
    }
    expect(find.textContaining('Студент QA'), findsOneWidget);
    if (expired) {
      expect(scope.lastAuthError, isNotNull);
      expect(OfflineAuthErrorReceipt.instance.accepts(scope.lastAuthError!), isTrue,
          reason: 'replay receipt requires exact SDK error and settled transport');
    }
    expect(calls, greaterThan(0));
    final admissionCalls = calls;
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
    for (var i = 0; i < 100 && find.text('qa.pdf').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(UnifiedChatScreen), findsOneWidget);
    expect(find.text('Локальное сообщение QA'), findsOneWidget);
    expect(find.text('qa.pdf'), findsOneWidget);
    expect(tester.widgetList<Image>(find.byType(Image))
        .where((image) => image.image is MemoryImage &&
            (image.image as MemoryImage).bytes.length == imageBytes.length &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)), isNotEmpty);
    expect(calls, admissionCalls);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Командный чат QA'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && find.text('Сообщение команды QA').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Сообщение команды QA'), findsOneWidget);
    for (var i = 0; i < 100 && tester.widgetList<Image>(find.byType(Image))
        .where((image) => image.image is MemoryImage &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)).isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.widgetList<Image>(find.byType(Image))
        .where((image) => image.image is MemoryImage &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)), isNotEmpty);
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
    expect(calls, admissionCalls);
    await tester.tap(find.byTooltip('Назад').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Локальный чат QA'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && find.text('qa.pdf').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Локальное сообщение QA'), findsOneWidget);
    expect(find.text('qa.pdf'), findsOneWidget);
    if (!revokeWithGate) {
      client.auth.notifyException(const AuthException('later unknown auth error'));
      await tester.pump();
      expect(find.text('qa.pdf'), findsNothing);
      expect(tester.widgetList<Image>(find.byType(Image)).where((image) =>
          image.image is MemoryImage &&
          listEquals((image.image as MemoryImage).bytes, imageBytes)), isEmpty);
    }
    await tester.runAsync(() async {
      final request = http.Request('POST', Uri.parse(
          'https://example.invalid/auth/v1/token?grant_type=refresh_token'));
      await expectLater(gate.send(request), throwsA(isA<RefreshTransportSuppressed>()));
    });
    expect(calls, admissionCalls);
    await tester.pump();
    if (expired) {
      expect(find.text('qa.pdf'), findsNothing);
      expect(tester.widgetList<Image>(find.byType(Image)).where((image) =>
          image.image is MemoryImage &&
          listEquals((image.image as MemoryImage).bytes, imageBytes)), isEmpty);
    }
    caps.block();
    await tester.pump();
    expect(find.text('Локальное сообщение QA'), findsNothing);
    expect(find.text('Сообщение команды QA'), findsNothing);
    expect(find.text('qa.pdf'), findsNothing);
    expect(tester.widgetList<Image>(find.byType(Image))
        .where((image) => image.image is MemoryImage &&
            listEquals((image.image as MemoryImage).bytes, imageBytes)), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose(); caps.dispose(); policyStore.dispose(); scope.dispose();
    await tester.runAsync(() async {
      await db.close();
      await policyDb.close();
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
