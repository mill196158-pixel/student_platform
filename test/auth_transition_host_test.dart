import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_transition_coordinator.dart';
import 'package:student_platform/src/core/auth_transition_host.dart';

void main() {
  testWidgets(
      'host retains one coordinator across theme rebuild and disposes it',
      (tester) async {
    AuthTransitionCoordinator? seen;
    AuthTransitionCoordinator? second;
    Widget app(Brightness brightness) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: AuthTransitionHost(
            child: Column(children: [
          Builder(builder: (context) {
            seen = AuthTransitionHost.maybeRead(context);
            return const SizedBox();
          }),
          Builder(builder: (context) {
            second = AuthTransitionHost.maybeRead(context);
            return const SizedBox();
          })
        ])));
    await tester.pumpWidget(app(Brightness.light));
    final first = seen!;
    expect(second, same(first));
    await tester.pumpWidget(app(Brightness.dark));
    expect(seen, same(first));
    expect(await first.run(() async => 7), 7);
    final gate = Completer<void>();
    final running = first.run(() => gate.future);
    await tester.pump();
    final queued = first.run(() async => 3);
    final failure = expectLater(queued, throwsStateError);
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await running;
    await failure;
    await expectLater(first.run(() async => 8), throwsStateError);
  });
}
