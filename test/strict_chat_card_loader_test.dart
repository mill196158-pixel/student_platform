import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/strict_chat_card_loader.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('batch binds results to each message and rejects a changed account', () async {
    var session = fakeSession('strict-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final network = Completer<http.Response>();
    var calls = 0;
    http.BaseRequest? requestInfo;
    final transport = MockClient((request) {
      calls++;
      requestInfo = request;
      return network.future;
    });
    final client = SupabaseClient('http://localhost:54321', 'test', httpClient: transport);
    final loader = StrictChatCardLoader(client: client);
    Future<dynamic> request(String message) => loader.load(scope: scope, chatId: 'chat',
        messageId: message, kind: 'collection', entityId: 'entity');
    final first = request('message-1');
    final second = request('message-2');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    network.complete(http.Response(jsonEncode([
      {'kind': 'group_collection', 'entity_id': 'entity', 'card_message_id': 'message-1',
       'available': true, 'status': 'open', 'title': 'Первый'},
      {'kind': 'group_collection', 'entity_id': 'entity', 'card_message_id': 'message-2',
       'available': false, 'status': 'unavailable'},
    ]), 200, request: requestInfo, headers: {'content-type': 'application/json'}));
    expect((await first).title, 'Первый');
    expect((await second).available, isFalse);

    final late = Completer<http.Response>();
    http.BaseRequest? lateRequest;
    final client2 = SupabaseClient('http://localhost:54321', 'test',
        httpClient: MockClient((request) { lateRequest = request; return late.future; }));
    final loader2 = StrictChatCardLoader(client: client2);
    final stale = loader2.load(scope: scope, chatId: 'chat', messageId: 'message-1',
        kind: 'collection', entityId: 'entity');
    final rejected = expectLater(stale, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    session = fakeSession('strict-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('strict-a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    late.complete(http.Response(jsonEncode([
      {'kind': 'group_collection', 'entity_id': 'entity', 'card_message_id': 'message-1',
       'available': true, 'status': 'open', 'title': 'Старый'}
    ]), 200, request: lateRequest, headers: {'content-type': 'application/json'}));
    await rejected;
    scope.dispose();
    await events.close();
    await client.dispose();
    await client2.dispose();
  });

  test('mismatched or malformed server rows never become a card', () async {
    final session = fakeSession('strict-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final client = SupabaseClient('http://localhost:54321', 'test', httpClient: MockClient((request) async =>
      http.Response(jsonEncode([{'kind':'group_collection','entity_id':'entity',
        'card_message_id':'other','available':true,'status':'open','title':'Чужой'}]), 200,
        request: request, headers: {'content-type':'application/json'})));
    final loader = StrictChatCardLoader(client: client);
    await expectLater(loader.load(scope: scope, chatId: 'chat', messageId: 'message',
        kind: 'collection', entityId: 'entity'), throwsFormatException);
    scope.dispose();
    await events.close();
    await client.dispose();
  });

  test('splits more than 50 requests and completes with exact bindings', () async {
    final session = fakeSession('strict-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final counts = <int>[];
    final client = SupabaseClient('http://localhost:54321', 'test',
      httpClient: MockClient((request) async {
        final payload = jsonDecode(request.body) as Map;
        final items = payload['p_items'] as List;
        counts.add(items.length);
        final rows = [for (final item in items) {...item as Map<String, dynamic>,
          'available': true, 'status': 'open', 'title': item['entity_id']}];
        return http.Response(jsonEncode(rows), 200, request: request,
            headers: {'content-type': 'application/json'});
      }));
    final loader = StrictChatCardLoader(client: client);
    final futures = [for (var i = 0; i < 51; i++) loader.load(scope: scope,
      chatId: 'chat', messageId: 'message-$i', kind: 'collection', entityId: 'entity-$i')];
    final result = await Future.wait(futures);
    expect(counts, [50, 1]);
    expect(result[50].title, 'entity-50');
    scope.dispose();
    await events.close();
    await client.dispose();
  });

  test('timeout reports an error and ignores late response', () async {
    final session = fakeSession('strict-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final late = Completer<http.Response>();
    http.BaseRequest? requestInfo;
    final client = SupabaseClient('http://localhost:54321', 'test',
      httpClient: MockClient((request) { requestInfo = request; return late.future; }));
    final loader = StrictChatCardLoader(client: client, timeout: const Duration(milliseconds: 10));
    await expectLater(loader.load(scope: scope, chatId: 'chat', messageId: 'message',
      kind: 'collection', entityId: 'entity'), throwsA(isA<TimeoutException>()));
    late.complete(http.Response('[]', 200, request: requestInfo,
      headers: {'content-type': 'application/json'}));
    await Future<void>.delayed(Duration.zero);
    scope.dispose();
    await events.close();
    await client.dispose();
  });
}
