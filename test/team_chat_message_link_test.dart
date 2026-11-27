import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/message_bubble.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cold_start_session_test.dart' show sessionFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exact team link is gated by the session that opened the message',
      (tester) async {
    const chatId = '12345678-1234-4123-8123-123456789abc';
    const url = 'studentplatform://chat/$chatId';
    final sent = Completer<void>();
    final reply = Completer<void>();
    final calls = <String>[];
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(links, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(links, null));

    late AuthSessionScope scope;
    await tester.runAsync(() async {
      await Supabase.initialize(
        url: 'https://team-chat-link.invalid',
        publishableKey: 'local-student-link-fixture',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.url.path, '/rest/v1/rpc/content_resolve_chat_cta');
          expect(jsonDecode(request.body), {
            'p_target_mode': 'chat_id',
            'p_target_id': chatId,
          });
          sent.complete();
          await reply.future;
          return http.Response(jsonEncode(chatId), 200,
              request: request, headers: {'content-type': 'application/json'});
        }),
      );
      final auth = Supabase.instance.client.auth;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await auth.setInitialSession(jsonEncode(sessionFixture(now + 3600)));
      scope = AuthSessionScope(
          currentSession: () => auth.currentSession,
          authEvents: auth.onAuthStateChange);
      await scope.ready;
    });
    addTearDown(Supabase.instance.dispose);
    addTearDown(() {
      if (!reply.isCompleted) reply.complete();
    });

    final base = Message(
      id: 'message-a',
      chatId: 'source-chat',
      authorId: 'test-user',
      authorLogin: 'test',
      authorName: 'QA',
      text: 'В рабочей группе $url. Другой адрес $url?redirect=1',
      at: DateTime(2026, 11, 27),
    );
    await tester.pumpWidget(AuthSessionScopeHost(
      createScope: () => scope,
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            MessageBubble(
                message: base, time: '11:00', showTeamChatLinks: true),
            MessageBubble(
              message: base.copyWith(id: 'local_draft'),
              time: '11:01',
              showTeamChatLinks: true,
            ),
            MessageBubble(
              message: base,
              time: '11:02',
              showTeamChatLinks: true,
              localOnlyUserId: 'test-user',
            ),
          ]),
        ),
      ),
    ));
    final link = find.byKey(const ValueKey('team-chat-message-link:$chatId'));
    expect(link, findsOneWidget);
    await tester.tap(link);
    await tester
        .runAsync(() => sent.future.timeout(const Duration(seconds: 2)));
    scope.invalidateForSignOut();
    reply.complete();
    for (var attempt = 0; attempt < 4; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }
    expect(calls, ['/rest/v1/rpc/content_resolve_chat_cta']);
    expect(find.text('Этот чат вам недоступен'), findsNothing);
    expect(link, findsOneWidget);
  });
}
