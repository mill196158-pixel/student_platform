import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/info_subjects_cache.dart';
import 'package:student_platform/src/ui/info/semester_subjects_picker.dart';
import 'package:student_platform/src/ui/info/useful_subject.dart';
import 'package:student_platform/src/ui/info/useful_subjects_repository.dart';
import 'package:student_ui/student_ui.dart';

const filters = [
  SubjectFilterOption('all', 'Все'),
  SubjectFilterOption('exams', 'Экзамены'),
  SubjectFilterOption('credits', 'Зачёты'),
  SubjectFilterOption('practices', 'Практики'),
  SubjectFilterOption('course', 'Курсовые / КР'),
];

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('picker scrolls but keeps apply visible: $size $brightness',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late BuildContext page;
        await tester.pumpWidget(MaterialApp(
          theme: ProductTheme.build(brightness: brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!),
          home: Scaffold(body: Builder(builder: (context) {
            page = context;
            return const SizedBox();
          })),
        ));
        final result = showSemesterSubjectsPicker<String>(page,
            semesters: List.generate(20, (i) => i + 1),
            semester: 4,
            currentSemester: 4,
            filters: filters,
            selectedFilter: 'all');
        await tester.pumpAndSettle();
        expect(find.text('Показать предметы').hitTestable(), findsOneWidget);
        expect(
            tester.getSize(find.byType(SemesterSubjectsPicker<String>)).width,
            lessThanOrEqualTo(600));
        await tester.scrollUntilVisible(find.text('20'), 200,
            scrollable: find.descendant(
                of: find.byType(SemesterSubjectsPicker<String>),
                matching: find.byType(Scrollable)));
        await tester.tap(find.text('20'));
        await tester.ensureVisible(find.text('Курсовые / КР'));
        await tester.tap(find.text('Курсовые / КР'));
        await tester.pump();
        await tester.tap(find.text('Показать предметы'));
        await tester.pumpAndSettle();
        final value = await result;
        expect(value?.semester, 20);
        expect(value?.filter, 'course');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('close discards draft and selected filter cannot be cleared',
      (tester) async {
    SemesterSubjectSelection<String>? result;
    var applied = 0;
    var closed = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(),
        home: Scaffold(
            body: SemesterSubjectsPicker<String>(
                semesters: const [1, 2, 3, 4],
                semester: 4,
                currentSemester: 4,
                filters: filters,
                selectedFilter: 'all',
                onApply: (value) {
                  applied++;
                  result = value;
                },
                onClose: () => closed++))));
    await tester.tap(find.text('1').hitTestable());
    await tester.tap(find.widgetWithText(ChoiceChip, 'Экзамены'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Экзамены'));
    await tester.pump();
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('subject-filter-exams')))
            .selected,
        isTrue);
    await tester.tap(find.byTooltip('Закрыть без применения'));
    expect(closed, 1);
    expect(applied, 0);
    expect(result, isNull);
  });

  testWidgets('empty semesters preserve nullable selection', (tester) async {
    SemesterSubjectSelection<String>? result;
    await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(),
        home: Scaffold(
            body: SemesterSubjectsPicker<String>(
                semesters: const [],
                semester: null,
                currentSemester: null,
                filters: filters,
                selectedFilter: 'all',
                onApply: (value) => result = value,
                onClose: () {}))));
    expect(find.text('Семестры пока не указаны'), findsOneWidget);
    await tester.tap(find.text('Показать предметы'));
    expect(result?.semester, isNull);
    expect(result?.filter, 'all');
  });

  testWidgets(
      'Info keeps draft isolated and preserves semester on filter-only apply',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
    InfoSubjectsCache.takePendingVote();
    final state = InfoPlanState(
      contextData: const AcademicContext(
          userId: 'picker-test',
          groupId: 'g',
          groupName: 'Группа',
          currentSemesterNumber: 4,
          hasActiveEnrollment: true),
      subjects: [
        for (final record in [
          (1, 'История', 'Экзамен'),
          (4, 'Алгебра', 'Экзамен'),
          (4, 'Физика', 'Зачёт')
        ])
          UsefulSubject(
              id: record.$2,
              title: record.$2,
              semesterNumber: record.$1,
              controlForm: record.$3,
              description: '',
              teacherName: '',
              teamName: '',
              teamIcon: '',
              teamGroupName: ''),
      ],
    );
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(),
        home: InfoScreen(
            debugUserId: 'picker-test',
            planLoader: () async {
              loads++;
              return state;
            })));
    await tester.pumpAndSettle();
    expect(find.text('2 дисциплины'), findsOneWidget);
    await tester.tap(find.text('Изменить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1').hitTestable());
    await tester.tap(find.byTooltip('Закрыть без применения'));
    await tester.pumpAndSettle();
    expect(find.text('Текущий семестр'), findsOneWidget);
    expect(find.text('2 дисциплины'), findsOneWidget);
    await tester.tap(find.text('Изменить'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Экзамены'));
    await tester.tap(find.text('Показать предметы'));
    await tester.pumpAndSettle();
    expect(find.text('Текущий семестр'), findsOneWidget);
    expect(find.text('1 дисциплина'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Экзамены'), findsOneWidget);
    await tester.tap(find.byTooltip('Показать все типы'));
    await tester.pumpAndSettle();
    expect(find.text('2 дисциплины'), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);
    await tester.tap(find.text('Изменить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1').hitTestable());
    await tester.tap(find.text('Показать предметы'));
    await tester.pumpAndSettle();
    expect(find.text('1-й семестр'), findsOneWidget);
    expect(find.text('История'), findsOneWidget);
    expect(loads, 1);
    expect(tester.takeException(), isNull);
  });
}
