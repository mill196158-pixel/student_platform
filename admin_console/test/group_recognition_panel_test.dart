import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_panel.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_repository.dart';

void main() {
  testWidgets('shows parsed course and admission year in safe preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 760,
            child: GroupRecognitionPanel(
              repository: LocalGroupRecognitionRepository(startYear: 2026),
              initialRows: [
                {'name': '1-сб(ПГС)-2'},
                {'name': 'bad group'},
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Проверка названий групп'), findsOneWidget);
    expect(find.textContaining('Сохранение пока отключено'), findsOneWidget);

    await tester.tap(find.text('Быстрая проверка'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Параллель: 1 · код: сбпгс · курс: 2'),
      findsOneWidget,
    );
    expect(find.textContaining('поступление: 2025'), findsOneWidget);
    expect(
      find.textContaining('Код программы ещё не подтверждён'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(find.textContaining('Формат названия не распознан'), findsOneWidget);
    expect(find.text('Только preview'), findsOneWidget);
  });
}
