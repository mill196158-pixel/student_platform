import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/single_flight_initialization.dart';

void main() {
  test('two startup callers share one initialization', () async {
    final runner = SingleFlightInitialization();
    final gate = Completer<void>();
    var calls = 0;
    Future<void> initialize() {
      calls++;
      return gate.future;
    }

    final first = runner.run(initialize);
    final second = runner.run(initialize);
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    gate.complete();
    await Future.wait([first, second]);
  });
  test('failed initialization releases flight for retry', () async {
    final runner = SingleFlightInitialization();
    var calls = 0;
    await expectLater(runner.run(() async {
      calls++;
      throw StateError('failed');
    }), throwsStateError);
    await runner.run(() async {
      calls++;
    });
    expect(calls, 2);
  });
}
