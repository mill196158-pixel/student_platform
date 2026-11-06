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
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('unopenable offline database preserves session and permits online home', (tester) async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('ordinary_cache_failure_')))!;
    final notDirectory = File('${dir.path}/not_a_directory');
    await tester.runAsync(() => notDirectory.writeAsString('preserve'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final project = SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '');
    const uid = 'fallback-owner';
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
      'iss': '$project/auth/v1', 'sub': uid,
      'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'role': 'authenticated', 'aud': 'authenticated', 'iat': now - 60, 'exp': now + 3600,
    })}.sig';
    final raw = jsonEncode({'access_token': token, 'refresh_token': 'synthetic',
      'token_type': 'bearer', 'expires_in': 3600, 'expires_at': now + 3600,
      'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {},
        'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}});
    final key = 'sb-${Uri.parse(project).host.split('.').first}-auth-token';
    SharedPreferences.setMockInitialValues({key: raw});
    final transport = MockClient((request) async {
      Object body = [];
      if (request.url.path.endsWith('/users')) body = [{'must_change_password': false}];
      if (request.url.path.endsWith('/rpc/get_my_profile')) body = [{'id': uid, 'name': 'Fallback'}];
      return http.Response(jsonEncode(body), 200, request: request,
          headers: {'content-type': 'application/json'});
    });
    await tester.runAsync(() => app.debugInitializeOrdinaryApp(client: transport,
      databasePath: notDirectory.path, databaseFactory: databaseFactoryFfi));
    expect(app.debugOrdinaryOfflineEnabled, isFalse);
    expect(Supabase.instance.client.auth.currentUser?.id, uid);
    final persisted = jsonDecode((await SharedPreferences.getInstance()).getString(key)!) as Map;
    expect((persisted['user'] as Map)['id'], uid);
    expect(persisted['refresh_token'], 'synthetic');
    expect(await tester.runAsync(() => notDirectory.readAsString()), 'preserve');
    await tester.pumpWidget(const app.StudentPlatformApp());
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(NavigationScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Supabase.instance.dispose());
    debugDefaultTargetPlatformOverride = null;
  });
}
