import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _LocalTransport extends http.BaseClient {
  final inner = IOClient(_RealSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final paths = <String>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.origin != 'http://127.0.0.1:55321') {
      throw StateError('Local Supabase is required');
    }
    paths.add(request.url.path);
    return inner.send(request);
  }
  @override
  void close() => inner.close();
}

class _RealSockets extends HttpOverrides {}

void main() {
  final configFile = Platform.environment['STUDENT_MATERIALS_LOCAL_CONFIG'];
  final manifestFile = Platform.environment['STUDENT_MATERIALS_LOCAL_MANIFEST'];
  if (configFile != null && manifestFile != null) {
    LiveTestWidgetsFlutterBinding().framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets('online subject opens its real team chat and returns from Files', (tester) async {
    final config = jsonDecode(File(configFile!).readAsStringSync()) as Map;
    final ids = jsonDecode(File(manifestFile!).readAsStringSync()) as Map;
    final title = 'QA subject ${(ids['offering'] as String).substring(0, 8)}';
    final body = 'QA subject discussion ${(ids['message'] as String).substring(0, 8)}';
    final transport = _LocalTransport();
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('keyboard_image_channel'), (_) async => null);
    await initializeDateFormatting('ru');
    await tester.runAsync(() => Supabase.initialize(url: 'http://127.0.0.1:55321',
        publishableKey: config['anonKey'] as String, httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false)));
    final client = Supabase.instance.client;
    addTearDown(transport.close);
    await tester.runAsync(() => client.auth.signInWithPassword(
        email: config['email'] as String, password: config['password'] as String));
    expect(client.auth.currentUser?.id == config['recipientId'], isTrue);
    await tester.pumpWidget(AuthSessionScopeHost(
        child: MaterialApp(theme: AppTheme.light().data, home: const InfoScreen())));
    Future<void> waitFor(Finder finder) async {
      for (var frame = 0; frame < 140 && finder.evaluate().isEmpty; frame++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(finder, findsWidgets);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await waitFor(find.text(title));
    await tester.ensureVisible(find.text(title).first);
    await tester.tap(find.text(title).first);
    await waitFor(find.text('Информация о предмете'));
    final action = find.text('Чат');
    await waitFor(action);
    await tester.ensureVisible(action.first);
    await tester.tap(action.first);
    await waitFor(find.byType(TeamDetailsScreen));
    await waitFor(find.text(body));
    await tester.tap(find.text('Файлы').first);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Чат').first);
    await waitFor(find.text(body));
    expect(transport.paths, containsAll(['/auth/v1/token', '/rest/v1/teams', '/rest/v1/chats',
        '/rest/v1/rpc/get_chat_messages_page']));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await Supabase.instance.dispose().timeout(const Duration(seconds: 12));
  }, skip: configFile == null || manifestFile == null);
}
