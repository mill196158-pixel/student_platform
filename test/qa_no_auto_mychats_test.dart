import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('chat list skips automatic settings migration only in QA', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    var writes = 0, reads = 0, manualMarks = 0;
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/get_my_chat_summaries')) {
          reads++;
          return http.Response(jsonEncode([{
            'chat_id': '11111111-1111-1111-1111-111111111111',
            'chat_type': 'team_main', 'team_id': '22222222-2222-2222-2222-222222222222',
            'team_name': 'Test Chat', 'title': 'Test Chat', 'settings_exists': false,
            'unread_count': 2, 'last_message_at': '2026-01-01T00:00:00Z'
          }]), 200, request: request, headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/chat_user_settings') && request.method != 'GET') {
          writes++;
          if (qaNoAutomaticWrites) throw StateError('Unexpected automatic settings write');
        }
        if (request.url.path.endsWith('/mark_chat_read')) manualMarks++;
        return http.Response('[]', 200, request: request,
            headers: {'content-type': 'application/json'});
      })));
    await signInWithFileSession(Supabase.instance.client, 'owner', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, Supabase.instance.client.auth.currentSession));
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
        child: const MyChatsScreen(enableRealtime: false))));
    for (var i = 0; i < 80 && find.text('Test Chat').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(reads, greaterThan(0));
    expect(find.text('Test Chat'), findsOneWidget);
    expect(writes, qaNoAutomaticWrites ? 0 : 1);
    expect(tester.takeException(), isNull);
    await tester.longPress(find.text('Test Chat'));
    for (var i = 0; i < 30 && find.text('Прочитано').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Прочитано'), findsWidgets);
    await tester.tap(find.text('Прочитано').last);
    for (var i = 0; i < 50 && manualMarks == 0; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(manualMarks, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await events.close();
    messenger.setMockMethodCallHandler(links, null);
  });
}
