import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

class DelayedChatPreferences extends InMemorySharedPreferencesStore {
  DelayedChatPreferences() : super.empty();
  final entered = Completer<void>();
  final release = Completer<void>();
  bool delayNext = true;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (delayNext && key.startsWith('flutter.chat_msg_cache_v1_')) {
      delayNext = false;
      entered.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}

Message message(String id, {bool failed = false}) => Message(
      id: id,
      clientId: failed ? id : null,
      chatId: 'chat',
      authorId: 'owner',
      authorLogin: '',
      authorName: 'Owner',
      text: id,
      at: DateTime.utc(2026),
      type: MessageType.text,
      deliveryStatus:
          failed ? MessageDeliveryStatus.failed : MessageDeliveryStatus.sent,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform original;
  late DelayedChatPreferences store;

  setUp(() async {
    original = SharedPreferencesStorePlatform.instance;
    store = DelayedChatPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    ChatMessageCacheStore.debugUserIdOverride = 'owner';
    await ChatMessageCacheStore.clearAllMemory();
  });

  tearDown(() async {
    if (!store.release.isCompleted) store.release.complete();
    await ChatMessageCacheStore.clearAllMemory();
    ChatMessageCacheStore.debugSetPrefs(null);
    ChatMessageCacheStore.debugUserIdOverride = null;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = original;
  });

  test('delayed old history cannot overwrite newer unconfirmed message', () async {
    final old = ChatMessageCacheStore.replace(chatId: 'chat', messages: [message('old')]);
    await store.entered.future;
    final newer = ChatMessageCacheStore.upsert('chat', message('unsent', failed: true));
    store.release.complete();
    await Future.wait([old, newer]);
    final raw = (await store.getAll())['flutter.chat_msg_cache_v1_owner_chat'] as String;
    final messages = (jsonDecode(raw) as Map)['messages'] as List;
    expect(messages.map((m) => m['id']), contains('unsent'));
  });

  test('clear after pending write does not restore the old envelope', () async {
    final old = ChatMessageCacheStore.replace(chatId: 'chat', messages: [message('old')]);
    await store.entered.future;
    final clear = ChatMessageCacheStore.clearChat('chat');
    store.release.complete();
    await Future.wait([old, clear]);
    expect((await store.getAll()).containsKey('flutter.chat_msg_cache_v1_owner_chat'), isFalse);
  });

  test('a new write after global clear remains present', () async {
    final old = ChatMessageCacheStore.replace(chatId: 'chat', messages: [message('old')]);
    await store.entered.future;
    final clear = ChatMessageCacheStore.clearAllPersistent();
    final newer = ChatMessageCacheStore.replace(chatId: 'chat', messages: [message('new')]);
    store.release.complete();
    await Future.wait([old, clear, newer]);
    final raw = (await store.getAll())['flutter.chat_msg_cache_v1_owner_chat'] as String;
    expect(((jsonDecode(raw) as Map)['messages'] as List).single['id'], 'new');
  });

  test('a stuck write in one chat does not block a different chat', () async {
    final old = ChatMessageCacheStore.replace(chatId: 'chat', messages: [message('old')]);
    await store.entered.future;
    final other = ChatMessageCacheStore.replace(
        chatId: 'other', messages: [message('fresh').copyWith(chatId: 'other')]);
    await other.timeout(const Duration(seconds: 2));
    expect((await store.getAll()).containsKey('flutter.chat_msg_cache_v1_owner_other'), isTrue);
    store.release.complete();
    await old;
  });
}
