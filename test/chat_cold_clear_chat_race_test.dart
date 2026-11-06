import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';

class DelayedPrefs extends InMemorySharedPreferencesStore {
  DelayedPrefs() : super.empty();
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Map<String, Object>> getAll() async {
    started.complete();
    await release.future;
    return super.getAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cold read and warmup cannot repopulate after chat clear', () async {
    final original = SharedPreferencesStorePlatform.instance;
    final store = DelayedPrefs();
    await store.setValue('String', 'flutter.chat_msg_cache_v1_a_chat',
        '{"v":1,"userId":"a","chatId":"chat","found":true,"messages":[]}');
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    ChatMessageCacheStore.debugUserIdOverride = 'a';
    addTearDown(() async {
      if (!store.release.isCompleted) store.release.complete();
      await ChatMessageCacheStore.clearAllMemory();
      ChatMessageCacheStore.debugUserIdOverride = null;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
    final read = ChatMessageCacheStore.read('chat', userId: 'a');
    final warmup = ChatMessageCacheStore.initializeCurrentUser();
    await store.started.future;
    final clear = ChatMessageCacheStore.clearChat('chat', userId: 'a');
    store.release.complete();
    await clear;
    expect((await read).found, isFalse);
    await warmup;
    expect(ChatMessageCacheStore.hasSnapshot('chat', userId: 'a'), isFalse);
  });
}
