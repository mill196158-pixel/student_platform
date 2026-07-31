import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('shows hero and vacancy title', (tester) async {
    const vacancy = ManagedVacancyCard(
      id: 'vac-1',
      origin: ContentOrigin.demo,
      payload: VacancyCardPayload(
        title: 'Junior Flutter Developer',
        companyName: 'Campus Lab',
        summary: 'Помощь с мобильным приложением.',
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudentJobsBoardView(
            cards: [vacancy],
          ),
        ),
      ),
    );

    expect(find.text('Доска вакансий'), findsOneWidget);
    expect(find.text('Junior Flutter Developer'), findsOneWidget);
    expect(find.text('Свежие предложения'), findsOneWidget);
    expect(find.textContaining('активн'), findsOneWidget);
  });

  testWidgets('detailPayload shows back and vacancy body', (tester) async {
    var backTapped = false;
    const vacancy = ManagedVacancyCard(
      id: 'vac-1',
      origin: ContentOrigin.demo,
      payload: VacancyCardPayload(
        title: 'Дизайнер презентаций',
        companyName: 'Студенческий проект',
        summary: 'Нужно красиво упаковывать идеи.',
        descriptionFull: 'Полное описание вакансии.',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentJobsBoardView(
            cards: const [vacancy],
            detailPayload: vacancy,
            onBack: () => backTapped = true,
          ),
        ),
      ),
    );

    expect(find.text('Доска вакансий'), findsNothing);
    expect(find.text('Дизайнер презентаций'), findsWidgets);
    await tester.tap(find.byTooltip('Назад'));
    expect(backTapped, isTrue);
  });
}
