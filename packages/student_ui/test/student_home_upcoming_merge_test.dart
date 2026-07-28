import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets(
      'day summary shows pairs only; upcoming merges by deadline with shared cap',
      (tester) async {
    final data = StudentHomeData(
      profile: const StudentHomeProfile(name: 'Минь', groupName: '1-См'),
      currentDate: DateTime(2026, 7, 28),
      lessons: const [],
      assignments: [
        StudentHomeAssignment(
          id: 'a-late',
          title: 'Позднее задание',
          subject: 'Команда',
          deadline: '10 авг.',
          dueAt: DateTime(2026, 8, 10),
        ),
        StudentHomeAssignment(
          id: 'a-soon',
          title: 'Скинуться на билеты',
          subject: 'Команда',
          deadline: '21 июн.',
          dueAt: DateTime(2026, 6, 21),
        ),
      ],
      groupActions: [
        StudentHomeGroupAction(
          id: 'topic|1',
          title: 'Доклад',
          kindLabel: 'Тема',
          deadlineText: '5 авг.',
          occursAt: DateTime(2026, 8, 5),
          isTopic: true,
        ),
        StudentHomeGroupAction(
          id: 'collection|2',
          title: 'На собаке',
          kindLabel: 'Сбор',
          deadlineText: '4 авг.',
          occursAt: DateTime(2026, 8, 4),
          isCollection: true,
        ),
        StudentHomeGroupAction(
          id: 'topic|3',
          title: 'Лишний дедлайн',
          kindLabel: 'Тема',
          deadlineText: '20 авг.',
          occursAt: DateTime(2026, 8, 20),
          isTopic: true,
        ),
      ],
      news: const [],
      assignmentsCount: 2,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StudentHomeView(data: data),
      ),
    );
    await tester.pumpAndSettle();

    // Day summary = pairs only (weekend empty state), not group actions.
    expect(find.text('Сводка дня'), findsOneWidget);
    expect(find.text('Сегодня пар нет'), findsOneWidget);
    // Group-action titles appear once (in upcoming), not duplicated into summary.
    expect(find.text('Доклад'), findsOneWidget);
    expect(find.text('На собаке'), findsOneWidget);

    // Upcoming: earliest 4 by deadline across both kinds.
    // Order: Скинуться на билеты (Jun 21), На собаке (Aug 4),
    // Доклад (Aug 5), Позднее задание (Aug 10). Cap drops «Лишний дедлайн».
    expect(find.text('Скинуться на билеты'), findsOneWidget);
    expect(find.text('На собаке'), findsOneWidget);
    expect(find.text('Доклад'), findsOneWidget);
    expect(find.text('Позднее задание'), findsOneWidget);
    expect(find.text('Лишний дедлайн'), findsNothing);

    final titles = [
      'Скинуться на билеты',
      'На собаке',
      'Доклад',
      'Позднее задание',
    ];
    final ys = [
      for (final t in titles) tester.getTopLeft(find.text(t)).dy,
    ];
    for (var i = 0; i < ys.length - 1; i++) {
      expect(ys[i], lessThan(ys[i + 1]),
          reason: 'Expected ${titles[i]} above ${titles[i + 1]}');
    }
  });

  testWidgets(
      'reported/confirmed collections leave upcoming; topic follow-up remains',
      (tester) async {
    final data = StudentHomeData(
      profile: const StudentHomeProfile(name: 'Минь', groupName: '1-См'),
      currentDate: DateTime(2026, 7, 28),
      lessons: const [],
      assignments: const [],
      groupActions: [
        StudentHomeGroupAction(
          id: 'collection|done',
          title: 'На собаке',
          kindLabel: 'Сбор',
          deadlineText: '4 авг.',
          occursAt: DateTime(2026, 8, 4),
          isCollection: true,
          isCompleted: true,
          statusLine: 'Исполнено',
        ),
        StudentHomeGroupAction(
          id: 'collection|reported',
          title: 'На билеты',
          kindLabel: 'Сбор',
          deadlineText: '5 авг.',
          occursAt: DateTime(2026, 8, 5),
          isCollection: true,
          isCompleted: true,
          statusLine: 'Исполнено',
        ),
        StudentHomeGroupAction(
          id: 'topic|1',
          title: 'Доклад',
          kindLabel: 'Темы',
          deadlineText: '6 авг.',
          occursAt: DateTime(2026, 8, 6),
          isTopic: true,
          followUpTitle: 'Подготовить «хоронить слона»',
          statusLine: 'Тема занята',
        ),
      ],
      news: const [],
    );

    await tester.pumpWidget(MaterialApp(home: StudentHomeView(data: data)));
    await tester.pumpAndSettle();

    expect(find.text('На собаке'), findsNothing);
    expect(find.text('На билеты'), findsNothing);
    expect(find.text('На проверке'), findsNothing);
    expect(find.text('Подготовить «хоронить слона»'), findsOneWidget);
    expect(find.textContaining('Тема · список «Доклад»'), findsOneWidget);
    expect(find.text('Тема занята'), findsOneWidget);
    // Section title is outside the tinted card.
    expect(find.text('Ближайшие дела'), findsOneWidget);
  });

  testWidgets('undated assignments sort after dated ones and do not steal cap',
      (tester) async {
    final data = StudentHomeData(
      profile: const StudentHomeProfile(name: 'Минь', groupName: '1-См'),
      currentDate: DateTime(2026, 7, 28),
      lessons: const [],
      assignments: const [
        StudentHomeAssignment(
          id: 'a-undated',
          title: 'Без срока',
          subject: 'Команда',
          deadline: 'без срока',
        ),
      ],
      groupActions: [
        for (var i = 1; i <= 4; i++)
          StudentHomeGroupAction(
            id: 'topic|$i',
            title: 'Тема $i',
            kindLabel: 'Выбор темы',
            deadlineText: '$i авг.',
            occursAt: DateTime(2026, 8, i),
          ),
      ],
      news: const [],
      assignmentsCount: 1,
    );

    await tester.pumpWidget(MaterialApp(home: StudentHomeView(data: data)));
    await tester.pumpAndSettle();

    expect(find.text('Тема 1'), findsOneWidget);
    expect(find.text('Тема 2'), findsOneWidget);
    expect(find.text('Тема 3'), findsOneWidget);
    expect(find.text('Тема 4'), findsOneWidget);
    expect(find.text('Без срока'), findsNothing);
  });
}
