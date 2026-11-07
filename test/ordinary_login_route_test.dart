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
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Sink implements WebSocketSink {
  _Sink(this.controller);
  final StreamController<dynamic> controller;
  @override void add(dynamic data) {}
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override Future<void> addStream(Stream<dynamic> stream) async { await stream.drain<void>(); }
  @override Future<void> close([int? code, String? reason]) => controller.close();
  @override Future<void> get done => controller.done;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class _Socket implements WebSocketChannel {
  final controller = StreamController<dynamic>.broadcast();
  late final output = _Sink(controller);
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
  testWidgets('first ordinary online login opens home and saves project profile', (tester) async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('ordinary_login_')))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final project = SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '');
    const uid = 'synthetic-login-owner';
    String part(Object v) => base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({'iss': '$project/auth/v1', 'sub': uid,
      'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'role': 'authenticated',
      'aud': 'authenticated', 'iat': now - 60, 'exp': now + 3600})}.sig';
    final session = {'access_token': token, 'refresh_token': 'synthetic-refresh', 'token_type': 'bearer',
      'expires_in': 3600, 'expires_at': now + 3600, 'user': {'id': uid, 'aud': 'authenticated',
        'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}};
    var loginCalls = 0;
    final transport = MockClient((request) async {
      Object body = [];
      if (request.url.path.endsWith('/token')) { loginCalls++; body = session; }
      if (request.url.path.endsWith('/rpc/get_my_profile')) body = [{'id': uid, 'name': 'Тестовый вход'}];
      if (request.url.path.endsWith('/users')) {
        final row = {'id': uid, 'must_change_password': false};
        body = (request.headers['accept'] ?? '').contains('object') ? row : [row];
      }
      return http.Response(jsonEncode(body), 200, request: request, headers: {'content-type': 'application/json'});
    });
    await tester.runAsync(() => app.debugInitializeOrdinaryApp(client: transport,
        databasePath: dir.path, databaseFactory: databaseFactoryFfi,
        realtimeOptions: RealtimeClientOptions(transport: (_, __) => _Socket())));
    await tester.pumpWidget(const app.StudentPlatformApp()); await tester.pumpAndSettle();
    app.appRouter.go('/login');
    for (var i = 0; i < 10; i++) await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextFormField).at(0), 'synthetic');
    await tester.enterText(find.byType(TextFormField).at(1), 'synthetic-password');
    await tester.tap(find.text('Войти').last);
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      final nav = find.byType(NavigationScreen);
      if (nav.evaluate().isNotEmpty && !tester.widget<NavigationScreen>(nav).guest) break;
    }
    expect(loginCalls, 1);
    expect(Supabase.instance.client.auth.currentUser?.id, uid);
    expect(find.byType(NavigationScreen), findsOneWidget);
    final scope = AuthSessionScopeHost.maybeOf(tester.element(find.byType(NavigationScreen)))!;
    final home = HomeSnapshotCache(project: project, authScope: scope,
        currentUserId: () => scope.capture()?.userId, sessionGeneration: () => scope.generation,
        sessionIdentity: scope.capture);
    for (var i = 0; i < 100 && await home.read(uid, HomeSnapshotSection.profile) == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect((await home.read(uid, HomeSnapshotSection.profile))?.items.single['name'], 'Тестовый вход');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Supabase.instance.client.realtime.disconnect());
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.runAsync(() => Supabase.instance.dispose());
    debugDefaultTargetPlatformOverride = null;
  });
}
