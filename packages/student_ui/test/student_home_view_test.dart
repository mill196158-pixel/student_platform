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

  testWidgets(
      'late optional sections preserve Home geometry until the next visit',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 11, 27);
    const news = StudentHomeNews(
      id: 'late',
      title: 'Поздняя новость',
      subtitle: '',
      body: 'Текст',
      icon: Icons.info_outline,
      gradientColors: [Color(0xFFEBE3FD), Color(0xFFD4C6F6)],
    );
    StudentHomePromoPlacement promo(String title, String slot) =>
        StudentHomePromoPlacement(
          anchorKey: ValueKey(title),
          payload: HomePromoPayload(
            title: title,
            subtitle: '',
            iconKey: 'help',
            gradientColors: const [Colors.white, Colors.white],
            ctaLabel: '',
            dismissible: false,
            cardVariant: 'compact_icon',
          ),
          slot: slot,
        );

    final existing = promo('Готовое объявление', 'after_day_summary');
    final late = promo('Позднее объявление', 'after_news');
    Widget app(int visit, List<StudentHomeNews> articles,
            List<StudentHomePromoPlacement> promos) =>
        MaterialApp(
          home: StudentHomeView(
            contentLayoutVisit: visit,
            data: StudentHomeData(
              profile: const StudentHomeProfile(name: 'QA', groupName: 'G'),
              currentDate: now,
              lessons: const [],
              assignments: const [],
              news: articles,
            ),
            hideHomePromo: true,
            homePromoPlacements: promos,
          ),
        );
    double y(String text) => tester.getTopLeft(find.text(text)).dy;

    await tester.pumpWidget(app(0, [], [existing]));
    await tester.pumpAndSettle();
    final core = [
      y('Сводка дня'),
      y('Готовое объявление'),
      y('Ближайшие дела'),
    ];
    expect(find.text(news.title), findsNothing);
    expect(find.text(late.payload.title), findsNothing);

    await tester.pumpWidget(app(0, [], [late, existing]));
    await tester.pumpAndSettle();
    final lateY = y(late.payload.title);
    expect(lateY, greaterThan(core.last));

    await tester.pumpWidget(app(0, [news], [existing, late]));
    await tester.pumpAndSettle();
    expect([
      y('Сводка дня'),
      y('Готовое объявление'),
      y('Ближайшие дела'),
    ], core);
    expect(y(late.payload.title), lateY);
    expect(y(news.title), greaterThan(lateY));

    await tester.pumpWidget(app(1, [news], [existing, late]));
    await tester.pumpAndSettle();
    expect(y(news.title), lessThan(y(late.payload.title)));
    expect(y(late.payload.title), lessThan(y('Сводка дня')));
    expect(y('Сводка дня'), lessThan(y('Готовое объявление')));
    expect(y('Готовое объявление'), lessThan(y('Ближайшие дела')));
  });
}
