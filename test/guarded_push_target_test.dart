import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/guarded_push_target.dart';
import 'package:student_platform/src/services/push/push_payload.dart';

void main() {
  test('uses only the current summary, rejects ambiguity and strips payload',
      () async {
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final input = PushPayload(
        version: 1,
        type: 'dm_message',
        chatId: 'chat',
        peerId: 'untrusted',
        raw: {'title': 'private old text'});
    Future<PushPayload?> resolve(List<Object?> rows) =>
        resolveCurrentPushTarget(
            payload: input,
            barrier: barrier,
            isCurrent: () => true,
            fetchSummaries: () async => rows);
    final row = {'chat_id': 'chat', 'chat_type': 'dm', 'peer_id': 'server'};
    final result = await resolve([row]);
    expect(result?.peerId, 'server');
    expect(result?.raw, isEmpty);
    expect(await resolve([row, row]), isNull);
    expect(
        await resolve([
          {'chat_id': 'chat', 'chat_type': 'team_main', 'team_id': 'team'}
        ]),
        isNull);
    expect(await resolve([]), isNull);
  });
  test('discard late result after session/barrier close', () async {
    var owner = true;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => owner);
    final response = Completer<dynamic>();
    final pending = resolveCurrentPushTarget(
        payload: const PushPayload(
            version: 1,
            type: 'team_message',
            chatId: 'chat',
            teamId: 'untrusted'),
        barrier: barrier,
        isCurrent: () => owner,
        fetchSummaries: () => response.future);
    owner = false;
    barrier.close();
    response.complete([
      {'chat_id': 'chat', 'chat_type': 'team_main', 'team_id': 'team'}
    ]);
    expect(await pending, isNull);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)),
        isTrue);
  });
}
