import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'package:student_platform/src/services/presence/user_presence.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

class _Chat implements IChatService {
  _Chat(this.messages);
  final List<Message> messages;
  int marks = 0;
  @override ChatMode get mode => ChatMode.dm;
  @override bool get supportsAssignments => false;
  @override bool get supportsNotes => false;
  @override String get currentUserId => 'owner';
  @override String? get chatId => 'chat';
  @override Future<String> ensureChatId() async => 'chat';
  @override List<Message> get currentMessages => messages;
  @override ChatMessagesViewState get messagesViewState => ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.ready, messages: messages, hasSnapshot: true);
  @override Stream<ChatMessagesViewState> watchMessagesState() => Stream.value(messagesViewState);
  @override Stream<List<Message>> watchMessages() => Stream.value(messages);
  @override Future<Map<String, dynamic>> getUnreadMeta() async => {};
  @override Future<void> markRead(String id) async { marks++; }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('QA suppresses automatic presence and DM mark, preserves read and manual mark', (tester) async {
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    final calls = <String>[];
    await tester.runAsync(() => Supabase.initialize(
      url: 'https://example.test', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        calls.add(request.url.path);
        if (request.url.path.endsWith('/ensure_dm_chat')) {
          return http.Response('"created-chat"', 200, request: request,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('[]', 200, request: request,
            headers: {'content-type': 'application/json'});
      })));
    await signInWithFileSession(Supabase.instance.client, 'owner', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    await tester.runAsync(() => PresenceService.instance.touch());
    expect(calls.where((p) => p.endsWith('/touch_my_presence')).length,
        qaNoAutomaticWrites ? 0 : 1);
    final existing = DmChatService(peerId: 'peer', initialChatId: 'chat');
    expect(await existing.ensureChatId(), 'chat');
    final missing = DmChatService(peerId: 'peer');
    if (qaNoAutomaticWrites) {
      await expectLater(missing.ensureChatId(), throwsA(isA<CachedChatUnavailable>()));
    } else {
      expect(await tester.runAsync(() => missing.ensureChatId()), 'created-chat');
    }
    expect(calls.where((p) => p.endsWith('/ensure_dm_chat')).length,
        qaNoAutomaticWrites ? 0 : 1);
    final rows = await tester.runAsync(() => Supabase.instance.client.rpc('get_my_chat_summaries'));
    expect(rows, isA<List>());
    await tester.runAsync(() => existing.markRead('message'));
    expect(calls.where((p) => p.endsWith('/mark_chat_read')).length, 1);
    final service = _Chat([Message(id: 'm', chatId: 'chat', authorId: 'peer',
      authorLogin: 'peer', authorName: 'Peer', text: 'Readable message', at: DateTime.utc(2026))]);
    await tester.pumpWidget(MaterialApp(home: UnifiedChatScreen(service: service, title: 'QA')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(find.text('Readable message'), findsOneWidget);
    expect(service.marks, qaNoAutomaticWrites ? 0 : greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await existing.dispose();
    await missing.dispose();
    messenger.setMockMethodCallHandler(links, null);
  });
}
