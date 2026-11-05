import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/shared/workspace_page_header.dart';
import 'package:student_platform/src/ui/schedule/subject_diary_screen.dart';
import 'package:student_platform/src/ui/schedule/subject_diary/subject_diary.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final width in [390.0, 834.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('long diary title fits at $width, dark=$dark',
          (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          theme: ProductTheme.build(
              brightness: dark ? Brightness.dark : Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              padding: const EdgeInsets.only(top: 48),
              textScaler: TextScaler.linear(1.5),
            ),
            child: Scaffold(
                body: Column(children: [
              WorkspacePageHeader(
                title: 'Проектная практика. Часть 2. Длинное название предмета',
                subtitle: 'Дневник предмета',
                actions: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      onPressed: () {},
                      tooltip: 'Добавить',
                      icon: const Icon(Icons.add)),
                  IconButton(
                      onPressed: () {},
                      tooltip: 'Меню',
                      icon: const Icon(Icons.more_horiz)),
                ]),
              ),
              const Expanded(child: SizedBox()),
            ])),
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byTooltip('Меню')).right,
            lessThanOrEqualTo(width));
        final header = tester.getRect(find.byType(WorkspacePageHeader));
        expect(header.bottom, greaterThan(120));
        expect(tester.getRect(find.text('Дневник предмета')).bottom,
            lessThanOrEqualTo(header.bottom));
      });
    }
  }

  testWidgets('real subject content uses outer scroll and semantic text colors',
      (tester) async {
    final payload = SubjectCardPayload.tryParse({
      'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'canonical_name': 'Предмет с длинным названием',
      'department': 'Кафедра проектирования',
      'description': List.filled(80, 'Подробное описание предмета.').join(' '),
      'requirements': 'Последний раздел доступен при прокрутке',
      'section_order': ['description', 'requirements'],
    })!;
    final theme = ProductTheme.build(brightness: Brightness.dark);
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
            body: SingleChildScrollView(
                child: StudentSubjectCardPreview(
                    payload: payload, fitContent: true, width: 360)))));
    expect(find.byType(ListView), findsNothing);
    expect(find.text(payload.canonicalName), findsNothing);
    expect(find.text('Кафедра проектирования'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Описание')).style!.color,
        theme.colorScheme.primary);
    await tester.scrollUntilVisible(
        find.text('Последний раздел доступен при прокрутке'), 400);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin phone preview retains its frame by default',
      (tester) async {
    final payload = SubjectCardPayload.tryParse({
      'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'canonical_name': 'Предмет',
    })!;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StudentSubjectCardPreview(payload: payload, height: 420))));
    expect(find.text('Предмет'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.getSize(find.byType(StudentSubjectCardPreview)).height, 420);
  });

  testWidgets('diary failed read shows recovery instead of infinite loading',
      (tester) async {
    final records = Completer<List<SubjectDiaryEntry>>();
    await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(brightness: Brightness.dark),
        home: AllNotesScreen(subjectKey: 'Предмет', entriesFuture: records.future)));
    records.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('Не удалось загрузить записи'), findsOneWidget);
    expect(find.text('К дневнику'), findsOneWidget);
    expect(find.byType(ProductLoadingIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty subject files explain what will appear', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(),
        home: AllFilesScreen(
            subjectKey: 'Предмет', entriesFuture: Future.value([]))));
    await tester.pump();
    expect(find.text('Файлов пока нет'), findsOneWidget);
    expect(find.text('Документы и вложения предмета появятся здесь'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
