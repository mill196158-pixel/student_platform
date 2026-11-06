import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime.utc(2026, 1, 1);

  Message message(String id,
          {bool failed = false, MessageType type = MessageType.text}) => Message(
        id: id,
        clientId: failed ? id : null,
        chatId: 'chat',
        authorId: 'user',
        authorLogin: '',
        authorName: 'User',
        text: 'Привет',
        at: at,
        type: type,
        deliveryStatus: failed
            ? MessageDeliveryStatus.failed
            : MessageDeliveryStatus.sent,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    ChatMessageCacheStore.debugUserIdOverride = 'user';
    await ChatMessageCacheStore.clearAllMemory();
  });

  test('failed text survives duplicate-looking rows in either order', () async {
    for (final rows in [
      [message('local-a', failed: true), message('server')],
      [message('server'), message('local-a', failed: true)],
    ]) {
      await ChatMessageCacheStore.replace(chatId: 'chat', messages: rows);
      expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
          containsAll(['local-a', 'server']));
    }
  });

  test('realtime and page without client id preserve failed text after restart',
      () async {
    await ChatMessageCacheStore.replace(
        chatId: 'chat', messages: [message('local-a', failed: true)]);
    await ChatMessageCacheStore.reconcileUpsert('chat', message('server'));
    await ChatMessageCacheStore.applyLatestServerPage(
        chatId: 'chat', serverPage: [message('server')], pageLimit: 50);
    await ChatMessageCacheStore.clearAllMemory();
    final result = await ChatMessageCacheStore.read('chat');
    expect(result.messages.map((m) => m.id), containsAll(['local-a', 'server']));
  });

  test('explicit acknowledgement removes only the matching failed message',
      () async {
    await ChatMessageCacheStore.replace(chatId: 'chat', messages: [
      message('local-a', failed: true),
      message('local-b', failed: true),
    ]);
    await ChatMessageCacheStore.reconcileUpsert('chat', message('server'),
        clientId: 'local-a');
    final ids = ChatMessageCacheStore.messagesSync('chat').map((m) => m.id);
    expect(ids, containsAll(['local-b', 'server']));
    expect(ids, isNot(contains('local-a')));
  });

  test('non-text reconciliation keeps its existing behavior', () async {
    await ChatMessageCacheStore.replace(chatId: 'chat', messages: [
      message('local-a', failed: true, type: MessageType.forward),
      message('server', type: MessageType.forward),
    ]);
    expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
        ['server']);
  });
}
