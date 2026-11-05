import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/info/propose_vacancy_screen.dart';

void main() {
  testWidgets('vacancy options can be selected, cancelled, and reset',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProposeVacancyScreen()));
    Finder field() => find.ancestor(
          of: find.text('Формат занятости'),
          matching: find.byType(InkWell),
        ).first;
    await tester.ensureVisible(field());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    await tester.tap(field());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Стажировка'));
    await tester.pumpAndSettle();
    expect(find.text('Стажировка'), findsOneWidget);

    await tester.tap(field());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Стажировка'), findsOneWidget);

    await tester.tap(field());
    await tester.pumpAndSettle();
    await tester.tap(find.text('— не указано —').last);
    await tester.pumpAndSettle();
    expect(find.text('Стажировка'), findsNothing);
  });
}
