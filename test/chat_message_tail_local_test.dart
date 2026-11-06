import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

Message makeMessage(String id, int minute,
        {MessageDeliveryStatus status = MessageDeliveryStatus.sent,
        List<String> fileIds = const []}) =>
    Message(
      id: id,
      chatId: 'chat',
      authorId: 'user-a',
      authorLogin: '',
      authorName: 'A',
      text: id,
      at: DateTime.utc(2026, 1, 1).add(Duration(minutes: minute)),
      deliveryStatus: status,
      outboundFileIds: fileIds,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    await ChatMessageCacheStore.clearAllMemory();
  });
  tearDown(() async {
    await ChatMessageCacheStore.clearAllMemory();
    ChatMessageCacheStore.debugSetPrefs(null);
    ChatMessageCacheStore.debugUserIdOverride = null;
  });
  test(
      'server tail keeps older unconfirmed rows and attachments across reload and users',
      () async {
    final locals = [
      makeMessage('local_failed', -2,
          status: MessageDeliveryStatus.failed, fileIds: ['file-failed']),
      makeMessage('local_sending', -1,
          status: MessageDeliveryStatus.sending, fileIds: ['file-sending']),
    ];
    await ChatMessageCacheStore.replace(
        chatId: 'chat', userId: 'user-a', messages: locals);
    final server = List.generate(150, (i) => makeMessage('server-$i', i));
    await ChatMessageCacheStore.applyLatestServerPage(
        chatId: 'chat', userId: 'user-a', serverPage: server, pageLimit: 150);
    var snapshot = ChatMessageCacheStore.peek('chat', userId: 'user-a');
    expect(snapshot.messages.where((m) => !m.isLocal), hasLength(120));
    expect(snapshot.messages.where((m) => m.isLocal).map((m) => m.id),
        ['local_failed', 'local_sending']);
    await ChatMessageCacheStore.clearAllMemory();
    snapshot = await ChatMessageCacheStore.read('chat', userId: 'user-a');
    expect(snapshot.messages.first.outboundFileIds, ['file-failed']);
    expect(snapshot.messages[1].outboundFileIds, ['file-sending']);
    expect((await ChatMessageCacheStore.read('chat', userId: 'user-b')).found,
        isFalse);
  });
}
