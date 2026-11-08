import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';

void main() {
  testWidgets('reports only a partial estimate and offers no cleanup',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: CacheDiagnosticsScreen(
      measure: () async {
        calls++;
        return 12300000;
      },
    )));
    await tester.pump();
    expect(find.text('12.3 МБ'), findsOneWidget);
    expect(find.text('Частичная оценка'), findsOneWidget);
    expect(find.textContaining('не общий размер'), findsOneWidget);
    expect(find.textContaining('очистка пока недоступны'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    await tester.ensureVisible(find.text('Обновить'));
    await tester.tap(find.text('Обновить'));
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('timeout and error show unavailable; late value is ignored',
      (tester) async {
    final pending = Completer<int?>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
      timeout: const Duration(seconds: 1),
      measure: () {
        calls++;
        return calls == 1
            ? pending.future
            : Future<int?>.error(StateError('error'));
      },
    )));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Сейчас недоступно'), findsOneWidget);
    await tester.ensureVisible(find.text('Обновить'));
    await tester.tap(find.text('Обновить'));
    await tester.pump();
    pending.complete(1000000);
    await tester.pump();
    expect(find.text('Сейчас недоступно'), findsOneWidget);
    expect(find.text('1.0 МБ'), findsNothing);
  });

  testWidgets(
      'closing while measurement is pending does not update disposed UI',
      (tester) async {
    final pending = Completer<int?>();
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(measure: () => pending.future)));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(1);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
