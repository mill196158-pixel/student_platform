import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';

void main() {
  test('a confirmed sender completes while later Realtime reads are busy',
      () async {
    final refresh = TeamChatRefreshQueue();
    final first = Completer<void>(),
        second = Completer<void>(),
        third = Completer<void>();
    final calls = <String>[];
    final firstAck = refresh.schedule(() {
      calls.add('first');
      return first.future;
    });
    final followUp = [
      for (var i = 0; i < 3; i++)
        refresh.schedule(() {
          calls.add('second');
          return second.future;
        })
    ];
    first.complete();
    await firstAck;
    expect(calls, ['first', 'second']);
    final last = refresh.schedule(() {
      calls.add('third');
      return third.future;
    });
    second.complete();
    await Future.wait(followUp);
    expect(third.isCompleted, isFalse);
    expect(calls, ['first', 'second', 'third']);
    third.complete();
    await last;
  });
}
