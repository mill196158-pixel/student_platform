import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_gate.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/team_chat_send_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const membership = {'team_id': 'team', 'user_id': 'student'};
  const liveChat = {
    'chat_id': 'chat',
    'team_id': 'team',
    'chat_type': 'team_main'
  };

  http.Response response(Object body, {int status = 200}) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  Future<TeamChatSendAccess> load(
    Future<http.Response> Function(http.Request) handler, {
    bool Function()? isCurrent,
  }) async {
    final client = SupabaseClient('http://localhost:55321', 'fixture-key',
        httpClient: MockClient((request) async {
      final result = await handler(request);
      return http.Response(result.body, result.statusCode,
          request: request, headers: result.headers);
    }));
    try {
      return await loadTeamChatSendAccess(client,
          userId: 'student',
          teamId: 'team',
          mainChatId: Future.value('chat'),
          isCurrent: isCurrent ?? () => true);
    } finally {
      await client.dispose();
    }
  }

  test('uses exact membership and exact live main chat', () async {
    final requests = <http.Request>[];
    final result = await load((request) async {
      requests.add(request);
      return response(request.url.path.endsWith('/team_members')
          ? [membership]
          : [liveChat]);
    });
    expect(result, TeamChatSendAccess.allowed);
    expect(requests.map((request) => request.url.path), [
      '/rest/v1/team_members',
      '/rest/v1/rpc/get_my_chat_summaries',
    ]);
    expect(requests.first.url.queryParameters,
        containsPair('user_id', 'eq.student'));
    expect(
        requests.first.url.queryParameters, containsPair('team_id', 'eq.team'));
    expect(
        requests.last.url.queryParameters, containsPair('chat_id', 'eq.chat'));
    expect(
        requests.last.url.queryParameters, containsPair('team_id', 'eq.team'));
    expect(requests.last.url.queryParameters,
        containsPair('chat_type', 'eq.team_main'));
  });

  test('absent membership or archive remains read-only', () async {
    var requests = 0;
    expect(
        await load((_) async {
          requests++;
          return response([]);
        }),
        TeamChatSendAccess.readOnly);
    expect(requests, 1);
    expect(
        await load((request) async => response(
            request.url.path.endsWith('/team_members') ? [membership] : [])),
        TeamChatSendAccess.readOnly);
  });

  test('network failure is retryable and a mismatched result never grants send',
      () async {
    expect(
        await load((request) async => request.url.path.endsWith('/team_members')
            ? response([membership])
            : response({'message': 'unavailable'}, status: 503)),
        TeamChatSendAccess.unavailable);
    expect(
        await load((request) async =>
            response(request.url.path.endsWith('/team_members')
                ? [membership]
                : [
                    {...liveChat, 'chat_id': 'wrong-chat'}
                  ])),
        TeamChatSendAccess.unavailable);
  });

  test('a stale membership response cannot continue under a changed session',
      () async {
    final started = Completer<void>();
    final resume = Completer<void>();
    var current = true;
    final requests = <String>[];
    final pending = load((request) async {
      requests.add(request.url.path);
      started.complete();
      await resume.future;
      return response([membership]);
    }, isCurrent: () => current);
    await started.future;
    current = false;
    resume.complete();
    expect(await pending, TeamChatSendAccess.unavailable);
    expect(requests, ['/rest/v1/team_members']);
  });

  testWidgets('pending status has the same resting height as the real editor',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    const historyKey = ValueKey('history');
    Future<void> show(double safeBottom, Widget bar) => tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 568),
                padding: EdgeInsets.only(bottom: safeBottom),
              ),
              child: Scaffold(
                body: Column(children: [
                  const Expanded(child: SizedBox(key: historyKey)),
                  bar,
                ]),
              ),
            ),
          ),
        );
    for (final safeBottom in [0.0, 7.0, 34.0]) {
      await show(safeBottom,
          const ChatComposerGate.placeholder(status: 'Подключение к чату…'));
      expect(find.byType(EditableText), findsNothing);
      final pendingHistory = tester.getRect(find.byKey(historyKey));
      await show(
        safeBottom,
        Composer(
          controller: controller,
          pickedImagePath: null,
          onOpenEmoji: () {},
          onSend: () {},
          onClearPicked: () {},
          onPickImage: () async {},
          attachedFiles: const [],
          onRemoveFile: (_) {},
          onAddFile: (_) {},
        ),
      );
      expect(find.byType(EditableText), findsOneWidget);
      expect(tester.getRect(find.byKey(historyKey)), pendingHistory);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
