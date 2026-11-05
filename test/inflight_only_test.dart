import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/inflight_only.dart';

void main() {
  test('only concurrent work with the same key is joined', () async {
    final queue = InflightOnly<String, int>();
    final gate = Completer<int>();
    var calls = 0;
    Future<int> work() {
      calls++;
      return gate.future;
    }

    final first = queue.run('a', work);
    final second = queue.run('a', work);
    expect(calls, 1);
    final different = queue.run('b', () async => 3);
    gate.complete(7);
    expect(await Future.wait([first, second, different]), [7, 7, 3]);
    expect(
        await queue.run('a', () async {
          calls++;
          return 9;
        }),
        9);
    expect(calls, 2);
  });

  test('errors reach every waiter and the next call starts again', () async {
    final queue = InflightOnly<String, int>();
    final gate = Completer<int>();
    final one = queue.run('a', () => gate.future);
    final two = queue.run('a', () => gate.future);
    final outcomes = Future.wait([
      expectLater(one, throwsStateError),
      expectLater(two, throwsStateError),
    ]);
    gate.completeError(StateError('offline'));
    await outcomes;
    expect(await queue.run('a', () async => 4), 4);
  });

  test('late old completion after clear cannot remove new work', () async {
    final queue = InflightOnly<String, int>();
    final old = Completer<int>();
    final current = Completer<int>();
    final oldResult = queue.run('a', () => old.future);
    queue.clear();
    final currentResult = queue.run('a', () => current.future);
    old.complete(1);
    expect(await oldResult, 1);
    var called = false;
    final joined = queue.run('a', () async {
      called = true;
      return 3;
    });
    expect(called, isFalse);
    current.complete(2);
    expect(await currentResult, 2);
    expect(await joined, 2);
  });

  test('timeout permits retry and late underlying completion cannot remove it',
      () async {
    final queue = InflightOnly<String, int>();
    final old = Completer<int>();
    final current = Completer<int>();
    final timed = queue.run(
        'a', () => old.future.timeout(const Duration(milliseconds: 10)));
    await expectLater(timed, throwsA(isA<TimeoutException>()));
    final fresh = queue.run('a', () => current.future);
    old.complete(1);
    await Future<void>.delayed(Duration.zero);
    var called = false;
    final joined = queue.run('a', () async {
      called = true;
      return 3;
    });
    expect(called, isFalse);
    current.complete(2);
    expect(await Future.wait([fresh, joined]), [2, 2]);
  });

  test('owner, token, generation and object form distinct keys', () async {
    final queue = InflightOnly<(String, String, int, String), int>();
    final gate = Completer<int>();
    var calls = 0;
    Future<int> work() {
      calls++;
      return gate.future;
    }

    final pending = [
      queue.run(('a', 't', 1, 'photo'), work),
      queue.run(('b', 't', 1, 'photo'), work),
      queue.run(('a', 'u', 1, 'photo'), work),
      queue.run(('a', 't', 2, 'photo'), work),
      queue.run(('a', 't', 1, 'other'), work),
    ];
    expect(calls, 5);
    gate.complete(1);
    expect(await Future.wait(pending), [1, 1, 1, 1, 1]);
  });
}
