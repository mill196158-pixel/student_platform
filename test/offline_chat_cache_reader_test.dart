import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/data/chat_summaries_cache.dart';
import 'package:student_platform/src/ui/chats/data/offline_chat_cache_reader.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

void main() {
  test('distinguishes absent, empty, and damaged lists', () async {
    String? raw;
    final reader = OfflineChatCacheReader(readSummaries: (_) async => raw);
    expect((await reader.chats('a')).state, OfflineChatListState.missing);
    raw = '[]';
    final empty = await reader.chats('a');
    expect(empty.state, OfflineChatListState.available);
    expect(empty.chats, isEmpty);
    raw = '{broken';
    expect((await reader.chats('a')).state, OfflineChatListState.corrupt);
    raw = '[{"chatId":"valid","title":"Chat"},42]';
    final partial = await reader.chats('a');
    expect(partial.chats.single.id, 'valid');
    expect(partial.partiallyDamaged, isTrue);
  });

  test('always passes the explicit account to local readers', () async {
    final reads = <String>[];
    final reader = OfflineChatCacheReader(
      readSummaries: (uid) async {
        reads.add('list:$uid');
        return '[{"chatId":"chat-1","title":"Chat"}]';
      },
      readMessages: (chatId, uid) async {
        reads.add('messages:$uid:$chatId');
        return ChatCacheSnapshot.notFound;
      },
    );
    expect((await reader.chats('a')).chats.single.id, 'chat-1');
    expect((await reader.messages('b', 'chat-1')).found, isFalse);
    expect(reads, ['list:a', 'messages:b:chat-1']);
    await expectLater(reader.chats(' '), throwsArgumentError);
    expect(() => reader.messages('', 'chat-1'), throwsArgumentError);
  });

  test('preserves the distinction between missing and cached empty chat',
      () async {
    final reader = OfflineChatCacheReader(
      readMessages: (chatId, _) async => chatId == 'empty'
          ? const ChatCacheSnapshot(found: true, messages: [])
          : ChatCacheSnapshot.notFound,
    );
    expect((await reader.messages('a', 'empty')).found, isTrue);
    expect((await reader.messages('a', 'missing')).found, isFalse);
  });

  test('real local stores keep the same chat id isolated by account', () async {
    SharedPreferences.setMockInitialValues({});
    ChatSummariesCache.clearMemory();
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    await ChatSummariesCache.write(
        'owner-a', '[{"chatId":"shared","title":"Список А"}]');
    await ChatSummariesCache.write(
        'owner-b', '[{"chatId":"shared","title":"Список Б"}]');
    await ChatMessageCacheStore.replace(
      userId: 'owner-a',
      chatId: 'shared',
      messages: [
        Message(
            id: 'a',
            chatId: 'shared',
            authorId: 'owner-a',
            authorLogin: '',
            authorName: '',
            text: 'Private A',
            at: DateTime.utc(2026))
      ],
    );
    await ChatMessageCacheStore.replace(
      userId: 'owner-b',
      chatId: 'shared',
      messages: [],
    );
    final reader = OfflineChatCacheReader();
    expect((await reader.chats('owner-a')).chats.single.title, 'Список А');
    expect((await reader.chats('owner-b')).chats.single.title, 'Список Б');
    expect((await reader.messages('owner-a', 'shared')).messages.single.text,
        'Private A');
    expect((await reader.messages('owner-b', 'shared')).messages, isEmpty);
    expect((await reader.messages('owner-c', 'shared')).found, isFalse);
    ChatMessageCacheStore.debugSetPrefs(null);
    ChatSummariesCache.clearMemory();
  });
}
