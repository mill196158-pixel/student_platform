import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

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
  test('cold read keeps an optimistic message created while prefs load',
      () async {
    final original = SharedPreferencesStorePlatform.instance;
    final store = DelayedPrefs();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() async {
      if (!store.release.isCompleted) store.release.complete();
      await ChatMessageCacheStore.clearAllMemory();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
    final read = ChatMessageCacheStore.read('chat', userId: 'a');
    await store.started.future;
    final msg = Message(
        id: 'local',
        chatId: 'chat',
        authorId: 'a',
        authorLogin: '',
        authorName: '',
        text: 'draft',
        at: DateTime.utc(2026));
    final write = ChatMessageCacheStore.replace(
        chatId: 'chat', userId: 'a', messages: [msg]);
    store.release.complete();
    expect((await read).messages.single.id, 'local');
    await write;
  });
}
