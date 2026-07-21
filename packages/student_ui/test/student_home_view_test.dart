import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('renders real home composition and selects news', (tester) async {
    var selectedIndex = -1;
    final now = DateTime(2026, 7, 21);
    final data = StudentHomeData(
      profile: const StudentHomeProfile(
        name: 'Минь',
        groupName: '1-См(ВВ)-2',
      ),
      currentDate: now,
      lessons: const [
        StudentHomeLesson(
          subject: 'Базы данных',
          start: TimeOfDay(hour: 10, minute: 0),
          pairNumber: 2,
          room: '203',
        ),
      ],
      assignments: const [
        StudentHomeAssignment(
          id: 'assignment-1',
          title: 'Подготовить отчёт',
          subject: 'Базы данных',
          deadline: '23 июл.',
        ),
      ],
      news: const [
        StudentHomeNews(
          id: 'news-1',
          title: 'Главная стала полезнее',
          subtitle: 'Всё важное под рукой',
          body: 'Описание новости',
          icon: Icons.auto_awesome_rounded,
          gradientColors: [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
        ),
      ],
      totalLessonsToday: 1,
      assignmentsCount: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: StudentHomeView(
          data: data,
          onNewsTap: (index) => selectedIndex = index,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Привет, Минь 👋'), findsOneWidget);
    expect(find.text('Сводка дня'), findsOneWidget);
    expect(find.text('Ближайшие задания'), findsOneWidget);

    await tester.tap(find.text('Главная стала полезнее'));
    expect(selectedIndex, 0);
  });
}
