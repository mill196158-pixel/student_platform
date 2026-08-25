import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_repository.dart';
import 'package:student_platform_admin/features/import_studio/import_studio_screen.dart';

Widget _app() {
  return MaterialApp(
    home: Scaffold(
      body: ImportStudioScreen(
        repository: LocalImportStudioRepository(),
        curriculumPanelBuilder: (_) =>
            const Text('CURRICULUM_SPECIALIZED_PANEL'),
        groupPanelBuilder: (_) => const Text('GROUP_SPECIALIZED_PANEL'),
        calendarPanelBuilder: (_) => const Text('CALENDAR_SPECIALIZED_PANEL'),
      ),
    ),
  );
}

Future<void> _setDesktopSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('academic chain is visible and honest about readiness', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Академическая цепочка'), findsOneWidget);
    expect(find.text('Учебный план'), findsOneWidget);
    expect(find.text('Группы и студенты'), findsOneWidget);
    expect(find.text('График учебного процесса'), findsOneWidget);
    expect(find.text('Расписание и готовность'), findsOneWidget);
    expect(find.text('Не реализовано'), findsOneWidget);
    expect(
      find.textContaining('Валидация и apply расписания отсутствуют'),
      findsOneWidget,
    );
    expect(
      find.textContaining('обновляет существующих Auth-пользователей'),
      findsOneWidget,
    );
    expect(find.textContaining('редкий перевод на 2 курс'), findsOneWidget);
    expect(
      find.textContaining('не меняет глобальные academic_terms'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Расширенные импорты XLSX'),
      700,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Расширенные импорты XLSX'), findsOneWidget);
    expect(
      find.textContaining('PDF и изображения используйте только'),
      findsOneWidget,
    );

    const legacyDomains = [
      'Преподаватели',
      'Предметы',
      'Студенты',
      'Группы',
      'Учебные планы',
      'Семестры',
      'Нагрузка (offerings)',
      'Связи преподавателей',
      'Зачисления',
    ];
    for (final label in legacyDomains) {
      await tester.scrollUntilVisible(
        find.text(label),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('primary chain actions open specialized panels directly', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    for (final entry in {
      'Открыть проверку плана': 'CURRICULUM_SPECIALIZED_PANEL',
      'Проверить группы и дубли': 'GROUP_SPECIALIZED_PANEL',
      'Открыть годовой график': 'CALENDAR_SPECIALIZED_PANEL',
    }.entries) {
      final button = find.text(entry.key);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      Navigator.of(tester.element(find.text(entry.value))).pop();
      await tester.pumpAndSettle();
    }

    final scheduleButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Проверка расписания недоступна'),
    );
    expect(scheduleButton.onPressed, isNull);
  });

  testWidgets('student action enters only the existing-user XLSX flow', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final action = find.text('Existing students XLSX');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.text('Студенты'), findsOneWidget);
    expect(
      find.textContaining('существующих Auth-пользователей'),
      findsWidgets,
    );
    expect(find.text('Загрузить XLSX'), findsOneWidget);
  });
}
