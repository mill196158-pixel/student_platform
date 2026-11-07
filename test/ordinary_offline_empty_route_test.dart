import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/local_snapshot_startup.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/navigation/cached_team_chat_directory.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ordinary router keeps shell and real offline builders without snapshots', (tester) async {
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
    online = false;
    networkCalls = 0;
    app.appRouter.go('/splash');
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.text('Расписание ещё не сохранено').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Расписание ещё не сохранено'), findsWidgets);
    expect(find.text('Сегодня выходной'), findsNothing);
    expect(find.text('Главная'), findsWidgets);
    for (final tab in ['База', 'Обучение', 'Расписание', 'Профиль']) {
      await tester.tap(find.text(tab).last);
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('Главная'), findsWidgets);
      final expected = switch (tab) {
        'База' => InfoScreen,
        'Обучение' => CachedTeamChatDirectory,
        'Расписание' => ScheduleScreen,
        _ => ProfileScreen,
      };
      expect(find.byType(expected), findsOneWidget);
      if (tab == 'Расписание') {
        final message = find.text('Не удалось загрузить расписание. Подключитесь к сети и повторите.');
        expect(message, findsOneWidget);
        expect(tester.widget<Text>(message).textAlign, TextAlign.center);
        final rect = tester.getRect(message);
        final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
        expect(rect.left, greaterThanOrEqualTo(24));
        expect(rect.right, lessThanOrEqualTo(width - 24));
      }
    }
    expect(find.text('Сохранённый профиль недоступен.'), findsOneWidget);
    expect(find.text('Сообщения'), findsOneWidget);
    await tester.tap(find.text('Сообщения'));
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byType(MyChatsScreen), findsOneWidget);
    expect(find.text('Сохранённые чаты недоступны.'), findsWidgets);
    expect(networkCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async { await closeProjectChatServerDatabase(db); await Supabase.instance.dispose(); });
    debugDefaultTargetPlatformOverride = null;
  });
}

