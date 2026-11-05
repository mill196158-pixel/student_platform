import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('existing cached chat is local, read-only and revoked synchronously',
      () async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('cached-user');
    final auth = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final caps = SessionCapabilities(auth);
    final attempt = caps.beginAuthorization(auth.capture()!)!;
    expect(caps.grant(SessionCapabilityMode.cacheOnly, attempt), isTrue);
    final message = Message(
        id: 'm',
        chatId: 'chat',
        authorId: 'cached-user',
        authorLogin: '',
        authorName: '',
        text: 'cached message',
        at: DateTime.utc(2026));
    await ChatMessageCacheStore.replace(
        userId: 'cached-user', chatId: 'chat', messages: [message]);
    final service = DmChatService.cachedOnly(
        peerId: 'peer', initialChatId: 'chat', capabilities: caps);
    expect(service.currentMessages.single.text, 'cached message');
    expect((await service.watchMessagesState().first).hasSnapshot, isTrue);
    final operations = <Future<Object?> Function()>[
      () async => service.markRead('m'),
      () async => service.sendText('test'),
      () async => service.retryFailedText(message),
      () async => service.toggleReaction('m', '👍'),
      () async => service.pinMessage('m', true),
      () async => service.deleteMessage('m'),
      () async => service.editOwnMessage('m', 'edit'),
      () async => service.upload(LocalAttach(
          path: '/file',
          name: 'file',
          mimeType: 'text/plain',
          size: 1,
          isImage: false)),
      () async => service.getFile('file'),
      () async => service.getUnreadMeta(),
      () async => service.loadOlderMessages(before: message),
    ];
    for (final operation in operations) {
      await expectLater(operation(), throwsA(isA<CapabilityDenied>()));
    }
    final first = <ChatMessagesViewState>[];
    final second = <ChatMessagesViewState>[];
    final firstSub = service.watchMessagesState().listen(first.add);
    final secondSub = service.watchMessagesState().listen(second.add);
    secondSub.pause();
    caps.block();
    await Future<void>.delayed(Duration.zero);
    secondSub.resume();
    await Future<void>.delayed(Duration.zero);
    expect(first, isNotEmpty);
    expect(second, isNotEmpty);
    expect(first.every((state) => state.messages.isEmpty), isTrue);
    expect(second.every((state) => state.messages.isEmpty), isTrue);
    await firstSub.cancel();
    await secondSub.cancel();
    expect(service.currentMessages, isEmpty);
    expect(service.chatId, isNull);
    expect(service.messagesViewState.error, isA<OperationInvalidated>());
    await expectLater(
        service.ensureChatId(), throwsA(isA<OperationInvalidated>()));
    await service.dispose();
    caps.dispose();
    auth.dispose();
    await events.close();
    ChatMessageCacheStore.debugSetPrefs(null);
  });

  test('missing snapshot is an error and a blank id never creates a chat',
      () async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('missing-user');
    final auth = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final caps = SessionCapabilities(auth);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(auth.capture()!)!);
    expect(
        () => DmChatService.cachedOnly(
            peerId: 'peer', initialChatId: '', capabilities: caps),
        throwsA(isA<CachedChatUnavailable>()));
    final service = DmChatService.cachedOnly(
        peerId: 'peer', initialChatId: 'missing', capabilities: caps);
    final state = await service
        .watchMessagesState()
        .firstWhere((state) => state.phase == ChatMessagesLoadPhase.error);
    expect(state.error, isA<CachedChatUnavailable>());
    expect(state.hasSnapshot, isFalse);
    await service.dispose();
    caps.dispose();
    auth.dispose();
    await events.close();
    ChatMessageCacheStore.debugSetPrefs(null);
  });

  test('a saved empty chat remains a valid snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('empty-user');
    final auth = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final caps = SessionCapabilities(auth);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(auth.capture()!)!);
    await ChatMessageCacheStore.replace(
        userId: 'empty-user', chatId: 'empty-chat', messages: []);
    final service = DmChatService.cachedOnly(
        peerId: 'peer', initialChatId: 'empty-chat', capabilities: caps);
    final state = await service.watchMessagesState().first;
    expect(state.phase, ChatMessagesLoadPhase.ready);
    expect(state.hasSnapshot, isTrue);
    expect(state.messages, isEmpty);
    expect(state.hasMoreBefore, isFalse);
    await service.dispose();
    caps.dispose();
    auth.dispose();
    await events.close();
    ChatMessageCacheStore.debugSetPrefs(null);
  });

  test('wrong-type cache becomes an unavailable state without network',
      () async {
    SharedPreferences.setMockInitialValues(
        {'chat_msg_cache_v1_corrupt-user_bad-chat': true});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('corrupt-user');
    final auth = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final caps = SessionCapabilities(auth);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(auth.capture()!)!);
    final service = DmChatService.cachedOnly(
        peerId: 'peer', initialChatId: 'bad-chat', capabilities: caps);
    expect(service.messagesViewState.error, isA<CachedChatUnavailable>());
    final state = await service
        .watchMessagesState()
        .firstWhere((value) => value.phase == ChatMessagesLoadPhase.error);
    expect(state.error, isA<CachedChatUnavailable>());
    await service.dispose();
    caps.dispose();
    auth.dispose();
    await events.close();
    ChatMessageCacheStore.debugSetPrefs(null);
  });

  test('late disk read after revoke cannot publish messages', () async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('late-user');
    final auth = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final caps = SessionCapabilities(auth);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(auth.capture()!)!);
    final pending = Completer<ChatCacheSnapshot>();
    final service = DmChatService.cachedOnly(
        peerId: 'peer',
        initialChatId: 'late-chat',
        capabilities: caps,
        cacheReader: (_, __) => pending.future);
    final updates = <ChatMessagesViewState>[];
    final subscription = service.watchMessagesState().listen(updates.add);
    caps.block();
    pending.complete(ChatCacheSnapshot(found: true, messages: [
      Message(
          id: 'm',
          chatId: 'late-chat',
          authorId: 'late-user',
          authorLogin: '',
          authorName: '',
          text: 'must stay hidden',
          at: DateTime.utc(2026))
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(updates.every((value) => value.messages.isEmpty), isTrue);
    expect(service.currentMessages, isEmpty);
    await subscription.cancel();
    await service.dispose();
    caps.dispose();
    auth.dispose();
    await events.close();
    ChatMessageCacheStore.debugSetPrefs(null);
  });
}
