import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
      'strict RPC reports complete and partial, rejects malformed and failures',
      () async {
    Object payload = [];
    var status = 200;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            jsonEncode(payload), status,
            headers: {'content-type': 'application/json'}, request: request)));
    final repo = SupabaseLearningRepository(client: client);
    final empty = await repo.loadConfirmedChatPage('c');
    expect(empty.source, TeamPageSource.serverRpc);
    expect(empty.messages, isEmpty);
    expect(empty.hasMore, isFalse);
    payload = [
      {
        'id': 'm',
        'chat_id': 'c',
        'created_at': '2026-01-01T00:00:00Z',
        'has_more': true,
        'author_id': null,
        'text': '',
        'type': 'text',
        'attachments': []
      }
    ];
    final partial = await repo.loadConfirmedChatPage('c');
    expect(partial.messages.single.id, 'm');
    expect(partial.hasMore, isTrue);
    payload = [{
      'id': 'forward', 'chat_id': 'c', 'created_at': '2026-01-01T00:00:00Z',
      'has_more': false, 'author_id': 'author', 'author_name': '', 'author_login': '',
      'type': 'forward', 'attachments': [
        {'id': 'file', 'chat_id': 'c', 'message_id': 'forward',
          'file_url': 'https://example.invalid/file', 'is_deleted': false},
        {'id': 'old-file', 'chat_id': 'c', 'message_id': 'forward',
          'file_url': 'https://example.invalid/old'}], 'text': jsonEncode({
        'from_chat_id': 'c', 'items': [{'id': 'original', 'author_id': 'a',
          'author_name': 'Автор', 'created_at': '2026-01-01T00:00:00Z',
          'text': 'Студент', 'attachments': []}]})
    }];
    final structured = (await repo.loadConfirmedChatPage('c')).messages.single;
    expect(structured.forward!.items.single.text, 'Студент');
    expect(structured.authorNameVerified, isFalse);
    expect(structured.attachments![0].deletionVerified, isTrue);
    expect(structured.attachments![1].deletionVerified, isFalse);
    expect(structured.toJson()['forward_payload'], isA<Map>());
    payload = {'wrong': 'shape'};
    await expectLater(repo.loadConfirmedChatPage('c'), throwsFormatException);
    payload = [
      {'id': 'm', 'chat_id': 'other', 'created_at': '2026-01-01T00:00:00Z'}
    ];
    await expectLater(repo.loadConfirmedChatPage('c'), throwsFormatException);
    status = 503;
    await expectLater(repo.loadConfirmedChatPage('c'), throwsA(anything));
    await client.dispose();
  });
}
