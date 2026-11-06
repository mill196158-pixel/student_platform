import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'support/scoped_draft_test_session.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Service implements IChatService {
  final messages = <Message>[];
  final markStarted = Completer<void>(), markRelease = Completer<void>();
  var markCalls = 0;
  @override
  ChatMode get mode => ChatMode.dm;
  @override
  bool get supportsAssignments => false;
  @override
  bool get supportsNotes => false;
  @override
  String get currentUserId => 'user';
  @override
  String? get chatId => 'chat';
  @override
  Future<String> ensureChatId() async => 'chat';
  @override
  List<Message> get currentMessages => messages;
  @override
  ChatMessagesViewState get messagesViewState => const ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.ready,
      messages: <Message>[],
      hasSnapshot: true);
  @override
  Stream<ChatMessagesViewState> watchMessagesState() =>
      Stream.value(messagesViewState);
  @override
  Stream<List<Message>> watchMessages() => Stream.value(messages);
  @override
  Future<Map<String, dynamic>> getUnreadMeta() async => {};
  @override
  Future<void> markRead(String id) async {
    markCalls++;
    if (!markStarted.isCompleted) markStarted.complete();
    await markRelease.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('closing scoped route does not mark messages read on dispose',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    var blockPrefetch = false, fileReads = 0, notificationReads = 0;
    final prefetchStarted = Completer<void>();
    final prefetchRelease = Completer<http.Response>();
    await tester.runAsync(() => Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: 'test',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/messages') && blockPrefetch) {
            if (!prefetchStarted.isCompleted) prefetchStarted.complete();
            return prefetchRelease.future;
          }
          if (request.url.path.endsWith('/chat_files')) fileReads++;
          if (request.url.path.endsWith('/app_notifications'))
            notificationReads++;
          return http.Response('[]', 200, request: request);
        }),
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    await tester.runAsync(() => signInForScopedDraft(Supabase.instance.client));
    var current = true;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => current);
    final service = _Service();
    await tester.pumpWidget(AuthSessionScopeHost(child: MaterialApp(
        home: UnifiedChatScreen(
            service: service,
            title: 'QA',
            onlineBarrier: barrier,
            sessionIsCurrent: () => current))));
    await tester.pump();
    service.messages.add(Message(
        id: 'server-id',
        chatId: 'chat',
        authorId: 'other',
        authorLogin: '',
        authorName: '',
        text: 'synthetic',
        at: DateTime.utc(2026)));
    current = false;
    barrier.close();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(service.markCalls, 0);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 2)),
        isTrue);
    // New route: a stale message query must not trigger file fetches after it
    // returns, and a completed mark-read must not start notification writes.
    current = true;
    bool oldGuard() => current;
    var newCurrent = true;
    bool newGuard() => newCurrent;
    final nextBarrier = OnlineSideEffectBarrier(ownerIsCurrent: oldGuard);
    final replacementBarrier = OnlineSideEffectBarrier(ownerIsCurrent: newGuard);
    final next = _Service();
    next.messages.add(Message(
        id: 'server-id',
        chatId: 'chat',
        authorId: 'other',
        authorLogin: '',
        authorName: '',
        text: 'synthetic',
        at: DateTime.utc(2026)));
    blockPrefetch = true;
    await tester.pumpWidget(AuthSessionScopeHost(child: MaterialApp(
        home: UnifiedChatScreen(
            key: const ValueKey('reused-chat'),
            service: next,
            title: 'QA',
            onlineBarrier: nextBarrier,
            sessionIsCurrent: oldGuard))));
    for (var i = 0;
        i < 80 &&
            (!prefetchStarted.isCompleted || !next.markStarted.isCompleted);
        i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(prefetchStarted.isCompleted, isTrue);
    expect(next.markStarted.isCompleted, isTrue);
    final originalState = tester.state(find.byType(UnifiedChatScreen));
    current = false;
    nextBarrier.close();
    await tester.pumpWidget(AuthSessionScopeHost(child: MaterialApp(
        home: UnifiedChatScreen(
            key: const ValueKey('reused-chat'),
            service: next,
            title: 'QA',
            onlineBarrier: replacementBarrier,
            sessionIsCurrent: newGuard))));
    expect(tester.state(find.byType(UnifiedChatScreen)), same(originalState));
    prefetchRelease.complete(http.Response(
        jsonEncode([
          {'id': 'm', 'file_id': 'file'}
        ]),
        200,
        headers: {'content-type': 'application/json'}));
    next.markRelease.complete();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(fileReads, 0);
    expect(notificationReads, 0);
    newCurrent = false;
    replacementBarrier.close();
    await tester.pumpWidget(const SizedBox());
    expect(await nextBarrier.closeAndDrain(timeout: const Duration(seconds: 2)),
        isTrue);
    await tester.runAsync(() => Supabase.instance.dispose());
    messenger.setMockMethodCallHandler(links, null);
  });
}
