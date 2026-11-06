import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('invalidating after floor read stops stale page from pruning pending',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://example.invalid',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) async => http.Response('null', 200,
            headers: {'content-type': 'application/json'}, request: r)));
    addTearDown(() async {
      await DmApi.clearSessionState();
      await ChatMessageCacheStore.clearOnLogout();
      await Supabase.instance.dispose();
    });
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final token = '${part({'alg': 'none'})}.${part({
          'sub': 'user',
          'iat': now,
          'exp': now + 3600
        })}.sig';
    await Supabase.instance.client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'test',
      'token_type': 'bearer',
      'expires_at': now + 3600,
      'user': {
        'id': 'user',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2022-01-01T00:00:00Z'
      }
    }));
    final msg = Message(
        id: 'local_pending',
        chatId: 'chat',
        authorId: 'user',
        authorLogin: '',
        authorName: '',
        text: 'keep',
        at: DateTime.utc(2026, 1),
        deliveryStatus: MessageDeliveryStatus.sending);
    await ChatMessageCacheStore.replace(
        chatId: 'chat', userId: 'user', messages: [msg]);
    DmApi.debugPrimeClearedAt('chat', DateTime.utc(2026, 6));
    final started = Completer<void>(), release = Completer<void>();
    DmApi.debugSyncPageLoader =
        ({required chatId, required limit, clearedAt}) async {
      started.complete();
      await release.future;
      return (messages: <Message>[], hasMore: false);
    };
    final sync =
        DmApi.syncLatest(chatId: 'chat', invalidateClearBoundary: false);
    await started.future;
    DmApi.invalidateClearedAt('chat');
    release.complete();
    expect((await sync).ok, isFalse);
    expect(
        ChatMessageCacheStore.messagesSync('chat', userId: 'user')
            .map((m) => m.id),
        contains('local_pending'));
    DmApi.debugPrimeClearedAt('chat', DateTime.utc(2026, 1));
    final eventStarted = Completer<void>(), eventRelease = Completer<void>();
    DmApi.debugLoadMessageById = ({required chatId, required messageId}) async {
      eventStarted.complete();
      await eventRelease.future;
      return Message(
          id: messageId,
          chatId: chatId,
          authorId: 'user',
          authorLogin: '',
          authorName: '',
          text: 'server',
          at: DateTime.utc(2026, 2));
    };
    final event =
        DmApi.debugHandleRealtimeUpsert(chatId: 'chat', messageId: 'server');
    await eventStarted.future;
    DmApi.invalidateClearedAt('chat');
    eventRelease.complete();
    await event;
    final after = ChatMessageCacheStore.messagesSync('chat', userId: 'user')
        .map((m) => m.id);
    expect(after, contains('local_pending'));
    expect(after, isNot(contains('server')));
  });
}
