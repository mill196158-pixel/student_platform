import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/shared/workspace_page_header.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final entry in <String, String?>{
    'Системы и сооружения водоснабжения': null,
    'Системы и сооружения водоснабжения (л.)': 'Лекция',
    'Системы и сооружения водоснабжения (пр.)': 'Практика',
    'Системы и сооружения водоснабжения (лаб.)': 'Лабораторная',
  }.entries) {
    testWidgets('lesson heading has no generic duplicate: ${entry.value}',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lesson = Lesson(
          id: 'local',
          date: DateTime(2026, 10, 31),
          week: 8,
          day: 'СБ',
          pairNum: 2,
          start: const TimeOfDay(hour: 10, minute: 0),
          end: const TimeOfDay(hour: 11, minute: 30),
          subjectRaw: entry.key);
      await tester.pumpWidget(MaterialApp(
          theme: ProductTheme.build(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!),
          home: LessonDetailsScreen(lesson: lesson)));
      await tester.pumpAndSettle();
      expect(find.text('Занятие'), findsOneWidget);
      if (entry.value == null) {
        final gap = tester.getTopLeft(find.text(lesson.subject)).dy -
            tester.getBottomLeft(find.byType(WorkspacePageHeader)).dy;
        expect(gap, inInclusiveRange(0, 12));
      } else {
        expect(find.text(entry.value!), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
