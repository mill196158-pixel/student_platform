import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/subjects/schedule_subject_review_screen.dart';
import 'package:student_platform_admin/features/academic/subjects/subject_item.dart';

void main() {
  const subjects = [
    SubjectItem(id: 's', canonicalName: 'Механика'),
    SubjectItem(
      id: 'old',
      canonicalName: 'Архивный',
      status: SubjectStatus.archived,
    ),
  ];
  final row = {
    'group_id': 'g',
    'raw_subject': 'Механка',
    'group_name': 'Тест',
    'lesson_count': 2,
    'first_date': '2026-03-01',
    'last_date': '2026-03-02',
  };
  Future<void> select(WidgetTester tester) async {
    await tester.tap(find.text('Сопоставить').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Архивный'), findsNothing);
    await tester.tap(find.text('Механика').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Сопоставить'));
    await tester.pumpAndSettle();
  }

  testWidgets('bind exact selected row once and reload empty state', (
    tester,
  ) async {
    var bound = false;
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScheduleSubjectReviewScreen(
          subjects: subjects,
          loadIssues: () async => bound ? [] : [row],
          bindSubject: (g, r, s) async {
            expect([g, r, s], ['g', 'Механка', 's']);
            calls++;
            bound = true;
            return {
              'subject_sync': [
                {'pending': 0},
              ],
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await select(tester);
    expect(calls, 1);
    expect(find.text('Все названия сопоставлены'), findsOneWidget);
  });
  testWidgets('pending data does not report completed matching', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScheduleSubjectReviewScreen(
          subjects: subjects,
          loadIssues: () async => [row],
          bindSubject: (g, r, s) async => {
            'subject_sync': [
              {'pending': 2},
            ],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await select(tester);
    expect(
      find.textContaining('Осталось несопоставленных занятий: 2'),
      findsOneWidget,
    );
    expect(find.text('Механка'), findsOneWidget);
  });
  testWidgets('failed bind retains row and can be retried', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScheduleSubjectReviewScreen(
          subjects: subjects,
          loadIssues: () async => [row],
          bindSubject: (g, r, s) async {
            calls++;
            throw Exception('denied');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await select(tester);
    expect(find.textContaining('Не удалось сопоставить.'), findsOneWidget);
    await select(tester);
    expect(calls, 2);
  });
  testWidgets('load error can retry', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScheduleSubjectReviewScreen(
          subjects: subjects,
          loadIssues: () async {
            if (calls++ == 0) throw Exception();
            return [row];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Механка'), findsOneWidget);
  });
}
