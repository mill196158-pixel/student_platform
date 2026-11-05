import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime.utc(2026, 1, 1);

  Message local(String id, String fileId) => Message(
        id: 'local_$id',
        chatId: 'chat',
        authorId: 'user',
        authorLogin: '',
        authorName: 'User',
        text: '',
        at: at,
        outboundFileIds: [fileId],
        deliveryStatus: MessageDeliveryStatus.sending,
      );
  Message server(String id, String fileId) => Message(
        id: id,
        chatId: 'chat',
        authorId: 'user',
        authorLogin: '',
        authorName: 'User',
        text: '',
        at: at,
        type: MessageType.file,
        attachments: [
          ChatFile(
            id: fileId,
            chatId: 'chat',
            messageId: id,
            fileName: 'a.pdf',
            fileKey: 'a',
            fileUrl: '',
            fileType: 'application/pdf',
            fileSize: 1,
            uploadedBy: 'user',
            uploadedAt: at,
          )
        ],
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugUserIdOverride = 'test';
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    await ChatMessageCacheStore.clearOnLogout();
    ChatMessageCacheStore.debugUserIdOverride = 'test';
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
  });

  test('page reconciles legacy local file with confirmed message', () {
    final result = ChatMessageCacheStore.reconcileLatestPage(
      existing: [local('a', 'file-a')],
      serverPage: [server('server-a', 'file-a')],
      pageLimit: 50,
    );
    expect(result.map((m) => m.id), ['server-a']);
  });

  test('distinct file sends remain distinct and one server matches one local',
      () {
    final result = ChatMessageCacheStore.reconcileLatestPage(
      existing: [
        local('a', 'file-a'),
        local('b', 'file-b'),
        local('c', 'file-a')
      ],
      serverPage: [server('server-a', 'file-a')],
      pageLimit: 50,
    );
    expect(result.map((m) => m.id), containsAll(['server-a', 'local_b']));
    expect(result.where((m) => m.id == 'local_a' || m.id == 'local_c'),
        hasLength(2));
  });

  test('server arriving after local is reconciled', () async {
    await ChatMessageCacheStore.replace(
        chatId: 'chat', messages: [local('a', 'file-a')]);
    await ChatMessageCacheStore.merge(
        chatId: 'chat', messages: [server('server-a', 'file-a')]);
    expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
        ['server-a']);
  });
  test('ambiguous file matches remain after repeated page and merge', () async {
    final initial = [local('a', 'file-a'), local('c', 'file-a')];
    final page = [server('server-a', 'file-a')];
    await ChatMessageCacheStore.replace(chatId: 'chat', messages: initial);
    await ChatMessageCacheStore.merge(chatId: 'chat', messages: page);
    await ChatMessageCacheStore.merge(chatId: 'chat', messages: page);
    final existing = ChatMessageCacheStore.messagesSync('chat');
    final result = ChatMessageCacheStore.reconcileLatestPage(
      existing: existing,
      serverPage: page,
      pageLimit: 50,
    );
    expect(result.map((m) => m.id),
        containsAll(['local_a', 'local_c', 'server-a']));
  });

  test('explicit acknowledgement removes only matching client id', () async {
    await ChatMessageCacheStore.replace(
        chatId: 'chat', messages: [local('a', 'file-a'), local('c', 'file-a')]);
    await ChatMessageCacheStore.reconcileUpsert(
        'chat', server('server-a', 'file-a'),
        clientId: 'local_a');
    expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
        containsAll(['local_c', 'server-a']));
    expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
        isNot(contains('local_a')));
  });

  test('ambiguous realtime acknowledgement retains all local sends', () async {
    await ChatMessageCacheStore.replace(
        chatId: 'chat', messages: [local('a', 'file-a'), local('c', 'file-a')]);
    await ChatMessageCacheStore.reconcileUpsert(
        'chat', server('server-a', 'file-a'));
    await ChatMessageCacheStore.reconcileUpsert(
        'chat', server('server-a', 'file-a'));
    expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
        containsAll(['local_a', 'local_c', 'server-a']));
  });
  test('server row without id cannot consume local file', () async {
    await ChatMessageCacheStore.replace(
        chatId: 'chat', messages: [local('a', 'file-a')]);
    await ChatMessageCacheStore.merge(
        chatId: 'chat', messages: [server('', 'file-a')]);
    expect(ChatMessageCacheStore.messagesSync('chat').map((m) => m.id),
        ['local_a']);
  });
}
