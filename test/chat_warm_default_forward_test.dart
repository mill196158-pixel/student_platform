import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/data/chat_summaries_cache.dart';
import 'package:student_platform/src/ui/chats/data/chat_warm_coordinator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('default warm-up formats a full forward before truncation', () async {
    SharedPreferences.setMockInitialValues({});
    ChatSummariesCache.clearMemory();
    const uid = 'default-warm-owner';
    final payload = '__FG__:${jsonEncode({
      'fg': 1,
      'from': 'source',
      'items': [{'id': 'message', 'text': List.filled(200, 'x').join()}],
    })}';
    const literal = 'Буквальный __FG__: обычный текст';
    const legacyLookingLiteral = '__FG__:{"from":123,"items":[{"id":1}]}';
    const noMarkerLiteral = '__FG__:{"from":"source","items":[{"id":"item"}]}';
    await Supabase.initialize(
      url: 'https://example.invalid',
      publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (!request.url.path.endsWith('/rpc/get_my_chat_summaries')) {
          throw StateError('Unexpected request');
        }
        return http.Response(jsonEncode([
          {'chat_type': 'dm', 'peer_id': 'a', 'last_message_id': 'a', 'body': payload},
          {'chat_type': 'dm', 'peer_id': 'b', 'last_message_id': 'b', 'body': literal},
          {'chat_type': 'dm', 'peer_id': 'c', 'last_message_id': 'c', 'content': {'text': payload}},
          {'chat_type': 'dm', 'peer_id': 'd', 'last_message_id': 'd', 'body': legacyLookingLiteral},
          {'chat_type': 'dm', 'peer_id': 'e', 'last_message_id': 'e', 'body': noMarkerLiteral},
          {'chat_type': 'team_main', 'team_kind': 'group_space', 'team_id': 'group',
           'team_name': '1-См-2', 'team_group_name': '1-См-2', 'title': '1-См-2',
           'last_message_id': 'g', 'content': {'card': 'topic_selection',
             'selection_id': '33333333-3333-3333-3333-333333333333'}},
        ]), 200, headers: {'content-type': 'application/json'}, request: request);
      }),
    );
    final client = Supabase.instance.client;
    await signInWithFileSession(client, uid, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    try {
      ChatWarmCoordinator.instance.start();
      await ChatWarmCoordinator.instance.refreshNow(force: true);
      final rows = (jsonDecode(ChatSummariesCache.readSync(uid)!) as List)
          .cast<Map<String, dynamic>>();
      final previews = {for (final row in rows) row['peerId']: row['lastMsgPreview']};
      expect(previews['a'], 'Пересланное сообщение');
      expect(previews['b'], literal);
      expect(previews['c'], 'Пересланное сообщение');
      expect(previews['d'], legacyLookingLiteral);
      expect(previews['e'], noMarkerLiteral);
      final group = rows.singleWhere((row) => row['chatId'] == null &&
          (row['team'] as Map)['id'] == 'group');
      expect(group['title'], 'Чат группы');
      expect((group['team'] as Map)['kind'], 'group_space');
      expect(group['lastActionCard'], isTrue);
    } finally {
      ChatWarmCoordinator.instance.stop();
      ChatSummariesCache.clearMemory();
      await Supabase.instance.dispose();
    }
  });
}
