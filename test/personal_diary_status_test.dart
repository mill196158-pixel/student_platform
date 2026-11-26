import 'package:student_ui/student_ui.dart'
    show ProductLoadingIndicator, ProductTheme;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/data/personal_diary_service.dart';
import 'package:student_platform/src/ui/profile/personal_diary_screen.dart';

class ControlledDiary extends PersonalDiaryService {
  ControlledDiary(
      {this.userId, this.otherTasks = const [], this.assignments = const []})
      : super(
            client: SupabaseClient('http://localhost:54321', 'test',
                authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final String? userId;
  final List<PersonalDiaryTask> otherTasks;
  final List<PersonalDiaryAssignment> assignments;
  final mutation = Completer<void>();
  final refresh = Completer<PersonalDiaryData>();
  int writes = 0;
  late final task = PersonalDiaryTask(
      id: 'fixture',
      subjectTitle: '',
      title: 'Test task',
      status: 'todo',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026));
  late final data = PersonalDiaryData(
      academicContext:
          AcademicContext(userId: userId, hasActiveEnrollment: false),
      availableSemesters: const [],
      selectedSemesterNumber: null,
      allSubjects: const [],
      subjects: const [],
      latestEntries: const [],
      publishedAssignments: assignments,
      personalTasks: [task, ...otherTasks],
      upcomingPersonalTasks: [task],
      totalEntries: 0,
      totalFiles: 0);
  @override
  PersonalDiaryData? peekCached({int? semesterNumber}) => null;
  @override
  Future<PersonalDiaryData?> loadCached({int? semesterNumber}) async => data;
  @override
  Future<PersonalDiaryData> loadAndCache({int? semesterNumber}) =>
      refresh.future;
  @override
  Future<void> updatePersonalTaskStatus(
      {required String taskId, required String status}) {
    writes++;
    return mutation.future;
  }
}

void main() {
  testWidgets('diary restores collapsed active tasks after reopening',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final service = ControlledDiary(userId: 'diary-user');
    await t
        .pumpWidget(MaterialApp(home: PersonalDiaryScreen(service: service)));
    await t.pumpAndSettle();
    expect(find.text('Test task'), findsOneWidget);
    await t.tap(find.text('Активные ближайшие'));
    await t.pumpAndSettle();
    expect(find.text('Test task'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t
        .pumpWidget(MaterialApp(home: PersonalDiaryScreen(service: service)));
    await t.pumpAndSettle();
    expect(find.text('Активные ближайшие'), findsOneWidget);
    expect(find.text('Test task'), findsNothing);
    await t.tap(find.text('Активные ближайшие'));
    await t.pumpAndSettle();
    expect(find.text('Test task'), findsOneWidget);
    service.refresh.complete(service.data);
    await t.pump();
  });
  Finder tab(String label) => find.descendant(
        of: find.byWidgetPredicate((widget) => widget is SegmentedButton),
        matching: find.text(label),
      );

  Future<void> showOnSmallIPhone(
      WidgetTester tester, PersonalDiaryService service) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      theme: ProductTheme.build().copyWith(platform: TargetPlatform.iOS),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(1.65)),
        child: child!,
      ),
      home: PersonalDiaryScreen(service: service),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target,
          {double delta = 180}) =>
      tester.scrollUntilVisible(target, delta,
          scrollable: find.byType(Scrollable).first);

  PersonalDiaryTask task(String title, String status, int order) =>
      PersonalDiaryTask(
        id: title,
        subjectTitle: 'Водоснабжение',
        title: title,
        status: status,
        createdAt: DateTime(2026, 12, order),
        updatedAt: DateTime(2026, 12, order),
      );

  testWidgets('iPhone diary tap outside and Done keep the search results',
      (tester) async {
    final service = ControlledDiary(otherTasks: [
      task('Расчёт расхода', 'todo', 1),
    ]);
    await showOnSmallIPhone(tester, service);
    final search = find.byType(TextField);
    await reveal(tester, search);
    await tester.enterText(search, 'Расчёт');
    await tester.pumpAndSettle();
    final input = tester.widget<EditableText>(find.byType(EditableText));
    expect(input.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tapAt(Offset(6, tester.getCenter(search).dy));
    await tester.pumpAndSettle();
    expect(input.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(input.controller.text, 'Расчёт');
    await reveal(tester, find.text('Расчёт расхода'));
    expect(find.text('Расчёт расхода'), findsOneWidget);
    expect(find.text('Test task'), findsNothing);
    await reveal(tester, search, delta: -180);
    await tester.tap(search);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(input.focusNode.hasFocus, isFalse);
    expect(input.controller.text, 'Расчёт');
    await reveal(tester, find.text('Расчёт расхода'));
    expect(find.text('Расчёт расхода'), findsOneWidget);
    await reveal(tester, search, delta: -180);
    await tester.tap(find.byTooltip('Очистить поиск'));
    await tester.pumpAndSettle();
    expect(input.controller.text, isEmpty);
    await reveal(tester, find.text('Test task'));
    expect(find.text('Test task'), findsOneWidget);
    expect(service.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'iPhone diary keeps old completed and extra active tasks accessible',
      (tester) async {
    final service = ControlledDiary(
      otherTasks: [
        task('Старая выполненная задача', 'done', 1),
        for (var day = 2; day <= 10; day++)
          task('Готовое дело $day', 'done', day),
        for (var day = 11; day <= 19; day++)
          task('Активное дело $day', 'todo', day),
      ],
      assignments: [
        PersonalDiaryAssignment(
          id: 'fixture-assignment',
          subjectOfferingId: 'mechanics',
          subjectTitle: 'Надёжность водоснабжения',
          title: 'Групповое задание',
          description: 'Проверенная работа',
          status: 'published',
          completedByMe: true,
          createdAt: DateTime(2026, 12, 20),
        ),
      ],
    );
    await showOnSmallIPhone(tester, service);
    await reveal(tester, tab('В работе'));
    expect(tab('В работе'), findsOneWidget);
    expect(tab('Готово'), findsOneWidget);
    expect(find.text('История'), findsNothing);
    await reveal(tester, find.text('Test task'));
    expect(find.text('Test task'), findsOneWidget);
    expect(find.text('Групповое задание'), findsNothing);
    expect(find.text('Активное дело 19'), findsNothing);
    await reveal(tester, find.text('Показать ещё'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Показать ещё'));
    await tester.pumpAndSettle();
    expect(find.text('Активное дело 19'), findsOneWidget);
    await reveal(tester, tab('Готово'), delta: -220);
    await tester.pumpAndSettle();
    await tester.tap(tab('Готово'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Групповое задание'));
    expect(find.text('Групповое задание'), findsOneWidget);
    expect(find.text('Test task'), findsNothing);
    expect(find.text('Старая выполненная задача'), findsNothing);

    final search = find.byType(TextField);
    await reveal(tester, search, delta: -180);
    await tester.enterText(search, 'старая');
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Старая выполненная задача'));
    expect(find.text('Старая выполненная задача'), findsOneWidget);
    expect(find.text('Групповое задание'), findsNothing);
    await reveal(tester, search, delta: -180);
    await tester.tap(find.byTooltip('Очистить поиск'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Показать ещё'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Показать ещё'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Старая выполненная задача'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Старая выполненная задача'), findsOneWidget);
    expect(service.writes, 0);
    expect(tester.takeException(), isNull);
  });
  for (final fail in [false, true]) {
    testWidgets('status stays visible, blocks duplicate writes, failure=$fail',
        (t) async {
      final service = ControlledDiary();
      await t
          .pumpWidget(MaterialApp(home: PersonalDiaryScreen(service: service)));
      await t.pump();
      await t.pump();
      expect(find.text('Test task'), findsOneWidget);
      await t.ensureVisible(find.text('Статус'));
      await t.tap(find.text('Статус'));
      await t.pump();
      await t.tap(find.text('Статус'));
      await t.pump();
      expect(service.writes, 1);
      expect(find.text('В работе'), findsNWidgets(2));
      expect(find.byType(ProductLoadingIndicator), findsNothing);
      if (fail) {
        service.mutation.completeError(StateError('offline'));
      } else {
        service.mutation.complete();
      }
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Test task'), findsOneWidget);
      expect(find.byType(ProductLoadingIndicator), findsNothing);
      expect(find.text(fail ? 'Нужно сделать' : 'В работе'),
          fail ? findsOneWidget : findsNWidgets(2));
      if (fail)
        expect(find.text('Не удалось сохранить статус. Повторите.'),
            findsOneWidget);
      service.refresh.complete(service.data);
      await t.pump();
      await t.pump();
      expect(find.byType(ProductLoadingIndicator), findsNothing);
      // A fresh canonical response supersedes the optimistic value.
      expect(find.text('Нужно сделать'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
