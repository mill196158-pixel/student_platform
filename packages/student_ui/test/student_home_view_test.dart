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
    expect(find.text('Ближайшие дела'), findsOneWidget);

    await tester.tap(find.text('Главная стала полезнее'));
    expect(selectedIndex, 0);
  });

  testWidgets('inserts section gaps between promos in same slot',
      (tester) async {
    final promo = HomePromoPayload.tryParse({
      'title': 'Promo A',
      'subtitle': 'Sub',
      'icon_key': 'help',
      'gradient_colors': ['#7367F0', '#B784F7'],
      'cta_label': 'Go',
      'dismissible': false,
      'home_slot': 'after_news',
    })!;
    final promoB = HomePromoPayload.tryParse({
      'title': 'Promo B',
      'subtitle': 'Sub B',
      'icon_key': 'help',
      'gradient_colors': ['#7367F0', '#B784F7'],
      'cta_label': 'Go',
      'dismissible': false,
      'home_slot': 'after_news',
    })!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentHomeView(
            data: StudentHomeData(
              profile: const StudentHomeProfile(name: 'Test', groupName: 'G'),
              currentDate: DateTime(2026, 7, 21),
              lessons: const [],
              assignments: const [],
              news: const [],
            ),
            homePromoPlacements: [
              StudentHomePromoPlacement(payload: promo, slot: 'after_news'),
              StudentHomePromoPlacement(payload: promoB, slot: 'after_news'),
            ],
            hideHomePromo: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Promo A'), findsOneWidget);
    expect(find.text('Promo B'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == kStudentHomeSectionGap,
      ),
      findsWidgets,
    );
  });
}
