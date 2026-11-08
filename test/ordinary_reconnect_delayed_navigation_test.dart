import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/navigation/reconnect_chat_host.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeSocketSink implements WebSocketSink {
  _FakeSocketSink(this.controller);
  final StreamController<dynamic> controller;
  @override void add(dynamic data) {}
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override Future<void> addStream(Stream<dynamic> stream) async { await stream.drain<void>(); }
  @override Future<void> close([int? closeCode, String? closeReason]) => controller.close();
  @override Future<void> get done => controller.done;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements WebSocketChannel {
  final StreamController<dynamic> controller = StreamController<dynamic>.broadcast();
  late final _FakeSocketSink output = _FakeSocketSink(controller);
  @override Stream<dynamic> get stream => controller.stream;
  @override WebSocketSink get sink => output;
  @override Future<void> get ready async {}
  @override String? get protocol => null;
  @override int? get closeCode => null;
  @override String? get closeReason => null;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ordinary cold offline shell reconnects to an online shell', (tester) async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('ordinary_reconnect_')))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final project = SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '');
    const uid = 'reconnect-owner';
    String part(Object v) => base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({'iss': '$project/auth/v1', 'sub': uid,
      'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'role': 'authenticated',
      'aud': 'authenticated', 'iat': now - 60, 'exp': now + 3600})}.sig';
    final raw = jsonEncode({'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer',
      'expires_in': 3600, 'expires_at': now + 3600, 'user': {'id': uid, 'aud': 'authenticated',
        'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}});
    SharedPreferences.setMockInitialValues({'sb-${Uri.parse(project).host.split('.').first}-auth-token': raw});
    final session = Session.fromJson(jsonDecode(raw))!;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final prior = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final home = HomeSnapshotCache(project: project, authScope: prior,
        currentUserId: () => prior.capture()?.userId, sessionGeneration: () => prior.generation,
        sessionIdentity: prior.capture);
    expect(await home.write(scope: home.captureScope(uid)!, section: HomeSnapshotSection.profile,
      items: [{'id': uid, 'name': 'Сохранённый студент'}], savedAt: DateTime.now()), isTrue);
    final db = (await tester.runAsync(() => openProjectChatServerDatabase(
      '${dir.path}/offline_chat_ordinary_v1.db', factory: databaseFactoryFfi)))!;
    final cache = ProjectChatServerCache(db: db, scope: prior,
      currentBinding: () => prior.bindingFor(prior.capture()!, '$project/auth/v1'), project: project);
    await tester.runAsync(() async {
      final summary = (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
      expect(await cache.saveSummaries(summary, [{'team': {'id': '', 'name': 'Peer',
        'teacher': '', 'groupCode': '', 'icon': ''}, 'title': 'Saved conversation',
        'chatId': 'chat', 'isDm': true, 'peerId': 'peer', 'unread': 0,
        'pinned': false, 'muted': false}]), isTrue);
      final ticket = (await cache.begin('chat'))!;
      expect(await cache.saveServerPage(ticket, [Message(id: 'message', chatId: 'chat',
        authorId: uid, authorLogin: uid, authorName: 'Owner', text: 'Saved message',
        at: DateTime.now())], hasMore: false), isTrue);
      await db.close();
    });
    prior.dispose(); await events.close();
    var online = false, healthCalls = 0;
    final pendingSummary = Completer<http.Response>();
    http.Request? summaryRequest;
    var summaryCalls = 0;
    var intentDispatched = false;
    debugReconnectSummaryDispatched = () => intentDispatched = true;
    addTearDown(() => debugReconnectSummaryDispatched = null);
    final transport = MockClient((request) async {
      if (!online) throw const SocketException('offline');
      if (request.url.path.endsWith('/auth/v1/health')) healthCalls++;
      Object body = [];
      if (request.url.path.endsWith('/users')) body = [{'id': uid, 'must_change_password': false}];
      if (request.url.path.endsWith('/rpc/get_my_chat_summaries')) { summaryCalls++; summaryRequest = request; return await pendingSummary.future; }
      if (request.url.path.endsWith('/rpc/get_my_profile')) body = [{'id': uid, 'name': 'Студент онлайн'}];
      return http.Response(jsonEncode(body), 200, request: request, headers: {'content-type': 'application/json'});
    });
    await tester.runAsync(() => app.debugInitializeOrdinaryApp(client: transport,
      databasePath: dir.path, databaseFactory: databaseFactoryFfi,
      realtimeOptions: RealtimeClientOptions(transport: (_, __) => _FakeSocket())));
    await tester.pumpWidget(const app.StudentPlatformApp()); await tester.pumpAndSettle();
    for (var i = 0; i < 60 && find.byType(NavigationScreen).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(NavigationScreen), findsOneWidget);
    expect(tester.widget<NavigationScreen>(find.byType(NavigationScreen)).cachedReader, isNotNull);
    await tester.tap(find.text('Профиль').last); await tester.pumpAndSettle();
    tester.widget<StudentProfileScreenPreview>(find.byType(StudentProfileScreenPreview)).onMessagesTap!();
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.text('Saved conversation').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Saved conversation'), findsOneWidget);
    await tester.tap(find.text('Saved conversation')); await tester.pumpAndSettle();
    expect(find.byType(DirectChatScreen), findsOneWidget);
    online = true;
    for (var i = 0; i < 200 && !intentDispatched; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(healthCalls, greaterThan(0));
    expect(tester.widgetList<NavigationScreen>(find.byType(NavigationScreen, skipOffstage: false))
        .any((nav) => nav.cachedReader == null), isTrue);
    expect(summaryRequest, isNotNull);
    expect(intentDispatched, isTrue);
    expect(summaryCalls, greaterThanOrEqualTo(1));
    final nav = app.appRouter.routerDelegate.navigatorKey.currentState!;
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Other route')))));
    await tester.pumpAndSettle();
    expect(find.text('Other route'), findsOneWidget);
    nav.pop(); await tester.pumpAndSettle();
    pendingSummary.complete(http.Response(jsonEncode([{'chat_id':'chat','chat_type':'dm',
      'peer_id':'peer','title':'Online peer'}]), 200, request:summaryRequest,
      headers:{'content-type':'application/json'}));
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(DirectChatScreen), findsNothing);
    expect(Supabase.instance.client.auth.currentUser?.id, uid);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Supabase.instance.client.removeAllChannels());
    await tester.runAsync(() => Supabase.instance.client.realtime.disconnect());
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.runAsync(() => Supabase.instance.dispose());
    debugDefaultTargetPlatformOverride = null;
  });
}
