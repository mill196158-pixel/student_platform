import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a lost group send response cannot retry a write that already committed',
      () async {
    const origin = 'https://mock-group-chat.invalid';
    const uid = '11111111-1111-4111-8111-111111111111';
    const teamId = '22222222-2222-4222-8222-222222222222';
    const chatId = '33333333-3333-4333-8333-333333333333';
    const messageIds = [
      '44444444-4444-4444-8444-444444444444',
      '55555555-5555-4555-8555-555555555555',
      '77777777-7777-4777-8777-777777777777',
    ];
    const text = 'Sent once before the connection changed';
    final requestBodies = <Map<String, dynamic>>[];
    final committed = <Map<String, dynamic>>[];
    final unexpectedRequests = <String>[];
    final firstWrite = Completer<void>();
    final dropReply = Completer<void>();
    final secondWrite = Completer<void>();
    final ackReply = Completer<void>();
    final detachedWrite = Completer<void>();
    final detachedReply = Completer<void>();
    SharedPreferences.setMockInitialValues({});

    await Supabase.initialize(
      url: origin,
      publishableKey: 'local-transport-fixture',
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false, detectSessionInUri: false),
      httpClient: MockClient((request) async {
        expect(request.url.origin, origin);
        final path = request.url.path;
        Object body;
        if (path == '/rest/v1/rpc/send_chat_message') {
          final params = jsonDecode(request.body) as Map<String, dynamic>;
          expect(params['p_team_id'], teamId);
          expect(params['p_text'], text);
          requestBodies.add(params);
          final index = committed.length;
          final id = messageIds[index];
          committed.add({
            'id': id,
            'chat_id': chatId,
            'author_id': uid,
            'author_name': 'QA',
            'type': 'text',
            'body': params['p_text'],
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
          if (index == 0) {
            firstWrite.complete();
            await dropReply.future;
            throw TimeoutException(
                'Fixture committed the message then dropped its reply');
          }
          if (index == 1) {
            secondWrite.complete();
            await ackReply.future;
          } else {
            detachedWrite.complete();
            await detachedReply.future;
          }
          body = id;
        } else if (path == '/rest/v1/rpc/get_chat_messages_page') {
          body = committed;
        } else if (path == '/rest/v1/chats') {
          body = [
            {'id': chatId, 'team_id': teamId, 'type': 'team_main'}
          ];
        } else if (path == '/rest/v1/messages') {
          final id = request.url.queryParameters['id'];
          body = committed.where((row) => id == 'eq.${row['id']}').toList();
        } else if (path == '/rest/v1/users' ||
            path == '/rest/v1/chat_files' ||
            path == '/rest/v1/rpc/get_user_profile') {
          body = const [];
        } else {
          unexpectedRequests.add(path);
          body = const [];
        }
        return http.Response(jsonEncode(body), 200,
            request: request, headers: {'content-type': 'application/json'});
      }),
    );
    addTearDown(Supabase.instance.dispose);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final auth = Supabase.instance.client.auth;
    Future<void> installSession(String version) =>
        auth.setInitialSession(jsonEncode({
          'access_token': '${part({'alg': 'none'})}.${part({
                'sub': uid,
                'iss': '$origin/auth/v1',
                'role': 'authenticated',
                'aud': 'authenticated',
                'session_id': '66666666-6666-4666-8666-666666666666',
                'jti': version,
                'iat': now,
                'exp': now + 3600,
              })}.sig',
          'refresh_token': 'local-fixture-$version',
          'token_type': 'bearer',
          'expires_at': now + 3600,
          'user': {
            'id': uid,
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
            'created_at': '2026-01-01T00:00:00Z',
          },
        }));
    await installSession('before-write');
    final scope = AuthSessionScope(
      currentSession: () => auth.currentSession,
      authEvents: auth.onAuthStateChange,
    );
    addTearDown(scope.dispose);
    await scope.ready;
    final initialGeneration = scope.generation;
    final cubit = TeamCubit(
      const Team(
          id: teamId, name: 'QA team', teacher: '', groupCode: '', icon: ''),
      repository: SupabaseLearningRepository(useLegacyTeamCache: false),
      authScope: scope,
    );
    addTearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });
    await cubit.retryLoadChat();

    final first = cubit.sendMessage('me', text, authorName: 'QA');
    final checkFirst =
        expectLater(first, throwsA(isA<UnconfirmedMessageSend>()));
    await firstWrite.future;
    final sending = cubit.state.chat.single;
    await cubit.refreshMessageById(messageIds.first);
    expect(
        cubit.state.chat.where((row) => row.id == sending.id).single.isSending,
        isTrue);
    final server =
        cubit.state.chat.singleWhere((row) => row.id == messageIds.first);
    final recent = ChatMessageCacheStore.reconcileLatestPage(
        existing: [sending.copyWith(chatId: chatId)],
        serverPage: [server],
        pageLimit: 20);
    expect(recent.any((row) => row.id == sending.id), isTrue);
    await installSession('same-session-before-timeout');
    await Future<void>.delayed(Duration.zero);
    expect(scope.generation, initialGeneration);
    dropReply.complete();
    await checkFirst;
    expect(committed.map((row) => row['id']), [messageIds.first]);
    final local = cubit.state.chat.singleWhere((row) => row.id == sending.id);
    expect(local.isUnconfirmed, isTrue);
    expect(local.isFailed, isFalse);
    expect(local.text, text);

    await cubit.retryFailedTextMessage(local);
    expect(requestBodies, hasLength(1));
    expect(committed.map((row) => row['id']), [messageIds.first]);

    // A second intentional send may have the same text. Keep both server IDs.
    final second = cubit.sendMessage('me', text, authorName: 'QA');
    await secondWrite.future;
    await installSession('same-session-before-ack');
    await Future<void>.delayed(Duration.zero);
    expect(scope.generation, initialGeneration);
    ackReply.complete();
    expect(await second, messageIds[1]);

    expect(committed.map((row) => row['id']), messageIds.take(2));
    expect(committed.map((row) => row['body']), [text, text]);
    expect(requestBodies, [requestBodies.first, requestBodies.first]);
    expect(
        cubit.state.chat.where((row) => row.id == messageIds[1]), hasLength(1));
    expect(cubit.state.chat.where((row) => row.isSending), isEmpty);
    expect(
        cubit.state.chat
            .where((row) => row.id == local.id)
            .single
            .isUnconfirmed,
        isTrue);
    await cubit.removeMessage(local.id);
    expect(cubit.state.chat.where((row) => row.id == local.id), isEmpty);
    expect(committed, hasLength(2));

    final detached = cubit.sendMessage('me', text, authorName: 'QA');
    await detachedWrite.future;
    expect(cubit.state.chat.any((row) => row.isSending), isTrue);
    expect(
        ChatMessageCacheStore.peek(chatId, userId: uid)
            .messages
            .any((row) => row.isSending),
        isFalse);
    await cubit.close();
    detachedReply.complete();
    expect(await detached, messageIds[2]);
    final reopened = ChatMessageCacheStore.peek(chatId, userId: uid).messages;
    expect(reopened.any((row) => row.isSending), isFalse);
    expect(reopened.where((row) => row.id == messageIds[2]), hasLength(1));
    expect(unexpectedRequests, isEmpty);
  });
}
