import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/local_snapshot_startup.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

class _MemoryStorage extends LocalStorage {
  _MemoryStorage(this.raw);
  String? raw;
  @override Future<void> initialize() async {}
  @override Future<bool> hasAccessToken() async => raw != null;
  @override Future<String?> accessToken() async => raw;
  @override Future<void> persistSession(String value) async { raw = value; }
  @override Future<void> removePersistedSession() async { raw = null; }
}

class _Schedule implements ScheduleRepository {
  @override Future<List<Lesson>> loadRange(DateTime from,
      {required int days, bool strict = false}) async => [];
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Learning implements SupabaseLearningRepository {
  @override Future<List<Team>> loadTeams(String group, {bool strict = false}) async => [];
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ordinary router opens saved home, chat and attachment offline', (tester) async {
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('ordinary_offline_route_')))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    const uid = 'synthetic-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final now = DateTime.now().toUtc();
    final project = SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '');
    String part(Object v) => base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
      'iss': '$project/auth/v1', 'sub': uid, 'session_id': sid,
      'role': 'authenticated', 'aud': 'authenticated',
      'iat': now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    })}.sig';
    final raw = jsonEncode({'access_token': token, 'refresh_token': 'synthetic',
      'token_type': 'bearer', 'expires_in': 3600,
      'expires_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {},
        'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}});
    var networkCalls = 0;
    var online = true;
    final transport = MockClient((request) async {
      networkCalls++;
      if (!online) throw const SocketException('offline');
      final profile = request.url.path.endsWith('/rpc/get_my_profile');
      return http.Response(profile
          ? jsonEncode([{'id': uid, 'name': 'Тестовый студент', 'group_name': 'Группа'}])
          : '[]', 200, request: request, headers: {'content-type': 'application/json'});
    });
    await tester.runAsync(() => Supabase.initialize(url: project, publishableKey: 'test',
      httpClient: transport, authOptions: FlutterAuthClientOptions(autoRefreshToken: false,
        localStorage: _MemoryStorage(null), detectSessionInUri: false)));
    final client = Supabase.instance.client;
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await tester.runAsync(() => scope.ready);
    OfflineSessionBinding? binding() => client.auth.currentSession == null ? null :
        OfflineSessionBinding.fromSession(client.auth.currentSession!, '$project/auth/v1');
    final db = (await tester.runAsync(() => openProjectChatServerDatabase(
      '${dir.path}/chats.sqlite', factory: databaseFactoryFfi)))!;
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: binding, project: project);
    final startup = LocalSnapshotStartup(scope: scope, issuer: '$project/auth/v1',
      restore: () => AuthSession.restoreSessionStatus(client),
      checkPolicy: () async => SettledPolicyStatus.unavailable);
    app.debugConfigureOrdinaryOffline(scope: scope, startup: startup, chatCache: cache);
    await tester.pumpWidget(const app.StudentPlatformApp());
    await tester.pumpAndSettle();
    expect(find.text('Без регистрации'), findsOneWidget);
    await tester.runAsync(() => client.auth.setInitialSession(raw));
    await tester.pump();
    final home = HomeSnapshotCache(project: project, authScope: scope,
      currentUserId: () => scope.capture()?.userId, sessionGeneration: () => scope.generation,
      sessionIdentity: scope.capture);
    await tester.runAsync(() async {
      final dashboard = HomeDashboardService(client: client, sessionScope: scope,
          scheduleRepository: _Schedule(), learningRepository: _Learning());
      await dashboard.load();
      for (var i = 0; i < 30 && await home.read(uid, HomeSnapshotSection.profile) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await home.read(uid, HomeSnapshotSection.profile))?.items.single['name'], 'Тестовый студент');
      expect(await home.read(uid, HomeSnapshotSection.schedule), isNotNull);
      dashboard.dispose();
      final summary = (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
      expect(await cache.saveSummaries(summary, [{
        'team': {'id': '', 'name': 'Друг', 'teacher': '', 'groupCode': '', 'icon': ''},
        'title': 'Сохранённый чат', 'chatId': 'chat', 'isDm': true, 'peerId': 'peer',
        'unread': 0, 'pinned': false, 'muted': false,
      }]), isTrue);
      final image = ChatFile(id: 'file', chatId: 'chat', messageId: 'message',
        fileName: 'saved.png', fileKey: 'saved.png', fileType: 'image/png',
        fileUrl: 'https://studentsplatform.storage.yandexcloud.net/chats/test/saved.png',
        fileSize: 3, uploadedBy: uid, uploadedAt: now);
      final key = ChatFileAccess.keyFor(image.fileUrl)!;
      final path = '${dir.path}/authorized_chat_files/$uid/${sha256.convert(utf8.encode('$uid:$key'))}';
      final file = File(path); await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII='));
      await File('$path.grant').writeAsString('chat-file-grant-v2:$sid');
      final ticket = (await cache.begin('chat'))!;
      expect(await cache.saveServerPage(ticket, [Message(id: 'message', chatId: 'chat',
        authorId: uid, authorLogin: uid, authorName: 'Студент', text: 'Сохранённое сообщение',
        at: now, attachments: [image])], hasMore: false), isTrue);
    });
    online = false;
    networkCalls = 0;
    app.appRouter.go('/splash');
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.textContaining('Тестовый студент').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('Тестовый студент'), findsOneWidget);
    await tester.tap(find.text('Профиль').last); await tester.pumpAndSettle();
    tester.widget<StudentProfileScreenPreview>(find.byType(StudentProfileScreenPreview)).onMessagesTap!();
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.text('Сохранённый чат').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Сохранённый чат'), findsOneWidget);
    await tester.tap(find.text('Сохранённый чат')); await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.text('Сохранённое сообщение').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Сохранённое сообщение'), findsOneWidget);
    expect(find.text('Сообщений пока нет'), findsNothing);
    final expectedImage = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII=');
    bool imageReady() => tester.widgetList<Image>(find.byType(Image)).any(
        (image) => image.image is MemoryImage &&
            listEquals((image.image as MemoryImage).bytes, expectedImage));
    for (var i = 0; i < 80 && !imageReady(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(imageReady(), isTrue);
    expect(networkCalls, 0);
    await tester.runAsync(() => client.auth.setInitialSession(
        raw.replaceAll('synthetic-owner', 'different-owner')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Сохранённое сообщение'), findsNothing);
    expect(imageReady(), isFalse);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async { await closeProjectChatServerDatabase(db); await Supabase.instance.dispose(); });
    debugDefaultTargetPlatformOverride = null;
  });
}
