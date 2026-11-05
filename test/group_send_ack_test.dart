import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/send_then_refresh.dart';

void main() {
  const id = '12345678-1234-1234-1234-123456789012';
  test('only valid supported acknowledgements confirm a message', () {
    for (final response in [
      id,
      {'id': id},
      [
        {'id': id}
      ]
    ]) {
      expect(parseSentChatMessageId(response), id);
    }
    for (final response in [
      null,
      '',
      false,
      {},
      {'id': 'bad'},
      [],
      [
        {'id': id},
        {'id': id}
      ]
    ]) {
      expect(() => parseSentChatMessageId(response),
          throwsA(isA<UnconfirmedMessageSend>()));
    }
  });
  test('failed send never refreshes', () async {
    var refreshes = 0;
    await expectLater(
        sendThenRefresh(
            send: () async => throw StateError('send'),
            isCurrent: () => true,
            refresh: (_) async {
              refreshes++;
            }),
        throwsStateError);
    expect(refreshes, 0);
  });
  test('invalid scope prevents dispatch', () async {
    var sends = 0;
    await expectLater(
        sendThenRefresh(
            send: () async {
              sends++;
              return id;
            },
            isCurrent: () => false,
            refresh: (_) async {}),
        throwsA(isA<SendScopeInvalidated>()));
    expect(sends, 0);
  });
  test('confirmed send remains successful when refresh fails or hangs',
      () async {
    for (final hang in [false, true]) {
      var sends = 0;
      final gate = Completer<void>();
      expect(
          await sendThenRefresh(
              send: () async {
                sends++;
                return id;
              },
              isCurrent: () => true,
              refresh: (_) =>
                  hang ? gate.future : Future.error(StateError('refresh')),
              refreshTimeout: const Duration(milliseconds: 10)),
          id);
      expect(sends, 1);
      if (hang) gate.complete();
    }
  });
  test('account, team or screen change skips refresh', () async {
    var current = true;
    var refreshed = false;
    final sent = Completer<String>();
    final pending = sendThenRefresh(
        send: () => sent.future,
        isCurrent: () => current,
        refresh: (_) async {
          refreshed = true;
        });
    current = false;
    sent.complete(id);
    expect(await pending, id);
    expect(refreshed, isFalse);
  });
}
