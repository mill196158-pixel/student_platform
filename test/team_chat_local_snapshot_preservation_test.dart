import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repo implements LearningRepository {
  @override
  Future<List<Message>> loadChat(String teamId) async => [
        Message(
            id: 'server',
            chatId: 'chat',
            authorId: 'other',
            authorLogin: '',
            authorName: 'B',
            text: 'server',
            at: DateTime.utc(2026, 1, 2))
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'team refresh does not replace unconfirmed file row with server-only legacy snapshot',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ChatMessageCacheStore.debugSetPrefs(prefs);
    ChatMessageCacheStore.debugUserIdOverride = 'user-a';
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            '[{"id":"chat"}]', 200,
            request: request, headers: {'content-type': 'application/json'})));
    final local = Message(
        id: 'local_failed',
        chatId: 'chat',
        authorId: 'user-a',
        authorLogin: '',
        authorName: 'A',
        text: 'failed',
        at: DateTime.utc(2026),
        deliveryStatus: MessageDeliveryStatus.failed,
        outboundFileIds: const ['file-id']);
    await ChatMessageCacheStore.replace(chatId: 'chat', messages: [local]);
    final cubit = TeamCubit(
        const Team(
            id: 'team', name: 'Team', teacher: '', groupCode: '', icon: ''),
        repository: _Repo());
    await cubit.retryLoadChat();
    // Allow its fire-and-forget legacy snapshot write to complete.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await ChatMessageCacheStore.clearAllMemory();
    final restored = await ChatMessageCacheStore.read('chat');
    expect(restored.messages.map((m) => m.id),
        containsAll(['local_failed', 'server']));
    expect(
        restored.messages
            .firstWhere((m) => m.id == 'local_failed')
            .outboundFileIds,
        ['file-id']);
    await cubit.close();
    ChatMessageCacheStore.debugSetPrefs(null);
    ChatMessageCacheStore.debugUserIdOverride = null;
    await Supabase.instance.dispose();
  });
}
