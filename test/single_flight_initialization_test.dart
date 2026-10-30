import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/single_flight_initialization.dart';

void main() {
  test(
      'concurrent startup callers wait for raster before init and cold message',
      () async {
    final runner = SingleFlightInitialization();
    final raster = Completer<void>();
    final initialization = Completer<void>();
    final events = <String>[];
    Future<void> initialize() async {
      events.add('initialize');
      await initialization.future;
    }

    final main = runner.run(initialize, after: raster.future);
    final host = runner.run(initialize, after: raster.future);
    final coldMessage = host.then((_) => events.add('initial-message'));
    expect(identical(main, host), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    raster.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['initialize']);
    initialization.complete();
    await coldMessage;
    expect(events, ['initialize', 'initial-message']);
  });
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
