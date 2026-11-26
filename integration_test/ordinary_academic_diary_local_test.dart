import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/data/personal_diary_service.dart';
import 'package:student_platform/src/ui/profile/personal_diary_screen.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/learning/assignment_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_ui/student_ui.dart' show ProductTheme;

import 'support/local_schema_http_client.dart';

class _HoldSavedDiary extends PersonalDiaryService {
  final saved = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> saveCached(PersonalDiaryData data, {int? semesterNumber}) async {
    await super.saveCached(data, semesterNumber: semesterNumber);
    saved.complete();
    await release.future;
  }
}

class _DiaryHttpClient extends LocalSchemaHttpClient {
  _DiaryHttpClient(super.port, this.delayTasks);
  final bool delayTasks;
  int taskPosts = 0;
  Completer<void>? holdTask;
  final taskResponses = <int>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (delayTasks &&
        request.method == 'POST' &&
        request.url.path.endsWith('/personal_diary_tasks')) {
      taskPosts++;
      if (holdTask != null) await holdTask!.future;
      final response = await super.send(request);
      taskResponses.add(response.statusCode);
      debugPrint('Delayed task POST response ${response.statusCode}');
      return response;
    }
    return super.send(request);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['STUDENT_DIARY_LOCAL'];
  testWidgets('lesson, group assignment, personal task and dated notes',
      (tester) async {
    final data = jsonDecode(fixture!) as Map<String, dynamic>;
    final schema = data['schema'] as String;
    expect(schema, matches(RegExp(r'^e2e_diary_[0-9a-f]{12}$')));
    expect(data['email'], '$schema@student.local');
    expect(SupabaseConfig.url, localSupabaseUrl);
    tester.testTextInput.register();
    SharedPreferences.setMockInitialValues({});
    final httpClient =
        _DiaryHttpClient(data['restPort'] as int, data['backlog'] == true);
    await Supabase.initialize(
      url: localSupabaseUrl,
      publishableKey: data['anon'] as String,
      httpClient: httpClient,
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: EmptyLocalStorage()),
      postgrestOptions: PostgrestClientOptions(schema: schema),
    );
    final client = Supabase.instance.client;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.auth.signOut();
      await Supabase.instance.dispose();
      httpClient.close();
    });
    final auth = await client.auth.signInWithPassword(
        email: data['email'] as String, password: data['password'] as String);
    expect(auth.user?.id, data['student']);
    final lessonDay = DateTime.parse(data['lessonDay'] as String);
    final archiveDay = DateTime.parse(data['archiveDay'] as String);
    final lesson = Lesson(
        id: data['lesson'] as String,
        date: lessonDay,
        week: 2,
        day: '',
        pairNum: 2,
        start: const TimeOfDay(hour: 10, minute: 30),
        end: const TimeOfDay(hour: 12, minute: 0),
        subjectRaw: 'E2E Mechanics',
        subjectOfferingId: data['offering'] as String);
    String displayDate(DateTime day) =>
        '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';
    Future<void> waitFor(Finder finder) async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsWidgets);
    }

    Future<void> animate() async {
      // The empty lesson day has a continuously animating illustration.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tap(Finder finder) async {
      await waitFor(finder);
      await tester.ensureVisible(finder.first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(finder.hitTestable().first);
      await animate();
    }

    Future<void> back() => tap(find.byTooltip('Назад'));

    Future<void> diary() async {
      await tap(find.text('Дневник предмета'));
      await waitFor(find.text('Frame calculation'));
    }

    Finder field({String? hint, String? label}) => find.byWidgetPredicate((w) =>
        w is TextField &&
        (hint == null || w.decoration?.hintText == hint) &&
        (label == null || w.decoration?.labelText == label));
    Future<void> noteText(String text) async {
      final input = field(hint: 'Заметка...');
      await waitFor(input);
      await tester.enterText(input, text);
      await tap(find.text('Сохранить'));
      await waitFor(find.text(text));
    }

    await tester
        .pumpWidget(MaterialApp(home: LessonDetailsScreen(lesson: lesson)));
    await diary();
    if (data['backlog'] == true) {
      final accounts = (data['accounts'] as List).cast<Map<String, dynamic>>();
      final tasks = client.from('personal_diary_tasks');
      final entries = client.from('subject_diary_entries');
      final secondLesson = Lesson(
          id: data['secondLesson'] as String,
          date: lessonDay,
          week: 2,
          day: '',
          pairNum: 4,
          start: const TimeOfDay(hour: 14, minute: 0),
          end: const TimeOfDay(hour: 15, minute: 30),
          subjectRaw: lesson.subjectRaw,
          subjectOfferingId: lesson.subjectOfferingId);
      Future<void> showLesson(Lesson selected) async {
        await tester.pumpWidget(MaterialApp(
            key: UniqueKey(), home: LessonDetailsScreen(lesson: selected)));
        await animate();
      }

      Future<void> login(int index) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await animate();
        await client.auth.signOut(scope: SignOutScope.local);
        final account = accounts[index];
        final result = await client.auth.signInWithPassword(
            email: account['email'], password: account['password']);
        expect(result.user!.id, account['student']);
        await showLesson(lesson);
      }

      const repeatedTitle = 'Backlog twin deadline';
      final now = DateTime.now();
      final early = DateTime(now.year, now.month + 1, 7);
      final late = DateTime(now.year, now.month + 1, 9);
      Future<void> searchTwins() async {
        await tester.enterText(
            field(hint: 'Поиск по дневнику предмета'), repeatedTitle);
        await animate();
      }

      Future<void> twin(DateTime due, String description) async {
        await tap(find.byIcon(Icons.add));
        await tap(find.text('Личная задача'));
        await tester.enterText(field(label: 'Название'), repeatedTitle);
        await tester.enterText(
            field(label: 'Описание, если нужно'), description);
        await tap(find.text('Добавить дедлайн'));
        final picker = find.byType(DatePickerDialog);
        await waitFor(picker);
        await tap(find.byTooltip(
            MaterialLocalizations.of(tester.element(picker)).nextMonthTooltip));
        await tap(
            find.descendant(of: picker, matching: find.text('${due.day}')));
        await tap(find.text('Выбрать'));
        await tap(find.text('Создать задачу'));
        await waitFor(find.text('до ${displayDate(due)}'));
      }

      final phase = Platform.environment['STUDENT_QA_PHASE'];
      if (phase == 'deadline') {
        const title = 'Month boundary task';
        final today = DateUtils.dateOnly(DateTime.now());
        final next = DateTime(today.year, today.month + 1, 1);
        final task = await PersonalDiaryService().createPersonalTask(
            title: title, subjectOfferingId: data['offering'], dueAt: today);
        expect(task.id.startsWith('local-'), isFalse);
        await showLesson(lesson);
        await diary();
        await tester.enterText(
            field(hint: 'Поиск по дневнику предмета'), title);
        await animate();
        await tap(find.text('до ${displayDate(today)}'));
        await tap(find.text('Изменить срок'));
        final picker = find.byType(DatePickerDialog);
        await tap(find.byTooltip(
            MaterialLocalizations.of(tester.element(picker)).nextMonthTooltip));
        await tap(find.descendant(of: picker, matching: find.text('1')));
        await tap(find.text('Сохранить'));
        await waitFor(find.text('до ${displayDate(next)}'));
        expect(find.text('до ${displayDate(today)}'), findsNothing);
        final rows = await tasks.select('id,due_at,status').eq('title', title);
        expect(rows, hasLength(1));
        expect(rows.single['id'], task.id);
        expect(rows.single['status'], 'todo');
        expect(displayDate(DateTime.parse(rows.single['due_at'])),
            displayDate(next));
        const doneTitle = 'Проверенный расчёт сети';
        final service = PersonalDiaryService();
        final doneTask = await service.createPersonalTask(title: doneTitle);
        expect(doneTask.id.startsWith('local-'), isFalse);
        await service.updatePersonalTaskStatus(
            taskId: doneTask.id, status: 'done');
        expect(
            (await tasks
                .select('status')
                .eq('id', doneTask.id)
                .single())['status'],
            'done');

        final screenshot = GlobalKey();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          key: UniqueKey(),
          debugShowCheckedModeBanner: false,
          theme: ProductTheme.build().copyWith(platform: TargetPlatform.iOS),
          builder: (_, child) => RepaintBoundary(key: screenshot, child: child),
          home: const PersonalDiaryScreen(),
        ));
        final diarySearch = field(hint: 'Поиск по дневнику');
        Finder tasksTab(String label) => find.descendant(
            of: find.byWidgetPredicate((widget) => widget is SegmentedButton),
            matching: find.text(label));
        Future<void> capture(String file) async {
          final out = Platform.environment['STUDENT_DIARY_EVIDENCE'];
          if (out == null) return;
          final boundary = screenshot.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$out/$file.png')
                .writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        }

        await waitFor(diarySearch);
        await tester.enterText(diarySearch, 'boundary task');
        await waitFor(find.text(title));
        final input = tester.widget<EditableText>(find.byType(EditableText));
        expect(input.focusNode.hasFocus, isTrue);
        await tester.tapAt(Offset(6, tester.getCenter(diarySearch).dy));
        await animate();
        expect(input.focusNode.hasFocus, isFalse);
        expect(input.controller.text, 'boundary task');
        expect(find.text(title), findsOneWidget);
        expect(find.text(doneTitle), findsNothing);
        await tester.tap(diarySearch);
        await animate();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await animate();
        expect(input.focusNode.hasFocus, isFalse);
        expect(input.controller.text, 'boundary task');
        await capture('active-search');
        await tap(find.byTooltip('Очистить поиск'));
        await tap(tasksTab('Готово'));
        await waitFor(find.text(doneTitle));
        expect(find.text(title), findsNothing);
        expect(find.text('История'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView).first, const Offset(0, 900));
        await animate();
        await capture('completed');
        await tap(tasksTab('В работе'));
        await waitFor(find.text(title));
        expect(find.text(doneTitle), findsNothing);
        debugPrint(
            'PASS iPhone diary search keeps query and result on outside touch and Done; two task tabs preserve saved completed task');

        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(
            MaterialApp(key: UniqueKey(), home: const PersonalDiaryScreen()));
        await animate();
        await tap(find.byIcon(Icons.add_rounded));
        await tap(find.text('Календарь дневника'));
        await waitFor(find.byType(GridView));
        Finder calendarDay(DateTime day) => find.descendant(
            of: find.byType(GridView),
            matching: find.byKey(ValueKey<DateTime>(DateUtils.dateOnly(day))));
        await tap(calendarDay(today));
        await waitFor(find.text('События на ${displayDate(today)}'));
        final calendar = find.byType(BottomSheet);
        expect(find.descendant(of: calendar, matching: find.text(title)),
            findsNothing);
        await tap(find.descendant(
            of: calendar, matching: find.byIcon(Icons.chevron_right_rounded)));
        await tap(calendarDay(next));
        await waitFor(find.text('События на ${displayDate(next)}'));
        expect(find.descendant(of: calendar, matching: find.text(title)),
            findsOneWidget);
        debugPrint(
            'E2E-072 PASS same own task UUID moved from today to first of next month and appears once in calendar');
        final published = await client
            .from('assignments')
            .select('id,due_at')
            .eq('title', 'Deadline notification example')
            .single();
        final due = DateTime.parse(published['due_at']).toLocal();
        expect(due.day, DateTime(due.year, due.month + 1, 0).day);
        final router = GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, __) =>
                  const Scaffold(body: Text('Open notifications'))),
          GoRoute(
              path: '/my-diary',
              builder: (_, state) => PersonalDiaryScreen(
                  assignmentId: state.uri.queryParameters['assignment'])),
        ]);
        addTearDown(router.dispose);
        await tester.pumpWidget(
            MaterialApp.router(key: UniqueKey(), routerConfig: router));
        await waitFor(find.text('Open notifications'));
        PushNavigation.markReady();
        addTearDown(PushNavigation.markNotReady);
        for (var attempt = 0; attempt < 2; attempt++) {
          final push = PushPayload.tryParse({
            'v': '1',
            'type': 'assignment',
            'assignment_id': published['id']
          })!;
          await PushNavigation.handle(
              tester.element(find.text('Open notifications')), push,
              force: true);
          await waitFor(find.text('Last-day assignment instructions'));
          await tester.binding.handlePopRoute();
          await animate();
          await waitFor(find.text('События на ${displayDate(due)}'));
          expect(
              find.descendant(
                  of: find.byType(BottomSheet),
                  matching: find.text('Deadline notification example')),
              findsOneWidget);
          await tester.binding.handlePopRoute();
          await animate();
          await tester.binding.handlePopRoute();
          await animate();
          await waitFor(find.text('Open notifications'));
        }
        debugPrint(
            'E2E-079 APP PASS push payload opened allowed assignment, two system returns left month-end selected twice');
        const prefix = 'Midnight test ';
        final midnight = DateTime(now.year, now.month + 1, 0, 23, 59);
        var localClock = midnight;
        final tomorrow =
            DateTime(midnight.year, midnight.month, midnight.day + 1);
        await PersonalDiaryService().createPersonalTask(
            title: '${prefix}old',
            dueAt: midnight,
            subjectOfferingId: data['offering']);
        await PersonalDiaryService().createPersonalTask(
            title: '${prefix}new',
            dueAt: tomorrow,
            subjectOfferingId: data['offering']);
        await tester.pumpWidget(MaterialApp(
            key: UniqueKey(),
            home: PersonalDiaryScreen(now: () => localClock)));
        final search = field(hint: 'Поиск по дневнику');
        await waitFor(search);
        await tester.enterText(search, prefix);
        await animate();
        final todayKey = find.byKey(ValueKey('today_tasks_${data['student']}'));
        final othersKey =
            find.byKey(ValueKey('active_tasks_${data['student']}'));
        Future<void> checkGroup(Finder group, String title) async {
          final list = find.byType(ListView).first;
          await tester.drag(list, const Offset(0, 1400));
          await animate();
          if (group.evaluate().isEmpty) {
            await tester.scrollUntilVisible(group, 180,
                scrollable: find.byType(Scrollable).first);
          }
          await tester.ensureVisible(group.first);
          await animate();
          final row =
              find.descendant(of: group, matching: find.text('$prefix$title'));
          await waitFor(row);
          expect(row, findsOneWidget);
        }

        await checkGroup(todayKey, 'old');
        await checkGroup(othersKey, 'new');
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        localClock = tomorrow.add(const Duration(minutes: 2));
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await animate();
        await checkGroup(todayKey, 'new');
        await checkGroup(othersKey, 'old');
        expect(find.text('${prefix}old'), findsOneWidget);
        expect(find.text('${prefix}new'), findsOneWidget);
        debugPrint(
            'E2E-080 APP PASS last day in background to new month: active tasks changed sections without duplicates');
        final held = _HoldSavedDiary();
        final rejected = expectLater(held.loadAndCache(), throwsStateError);
        try {
          await held.saved.future;
          await login(1);
        } finally {
          held.release.complete();
        }
        await rejected;
        debugPrint('PASS diary account change during pending cache save cannot return former student data');
        return;
      }
      if (phase == 'restart') {
        await searchTwins();
        for (final record in [
          (early, 'Early twin', 'Нужно сделать'),
          (late, 'Late twin', 'Готово')
        ]) {
          await tap(find.text('до ${displayDate(record.$1)}'));
          await waitFor(find.text(record.$2));
          await waitFor(find.text('E2E Mechanics • ${record.$3}'));
          await tester.tapAt(const Offset(5, 5));
          await animate();
        }
        final rows = await tasks
            .select('description,status,due_at')
            .eq('title', repeatedTitle)
            .order('due_at', ascending: true);
        expect(rows.map((r) => r['status']), ['todo', 'done']);
        expect(
            rows.map((r) => displayDate(DateTime.parse(r['due_at'] as String))),
            [displayDate(early), displayDate(late)]);
        debugPrint(
            'E2E-071 PASS independent native process logins, same title, two dates and states verified');
        return;
      }
      await twin(early, 'Early twin');
      await twin(late, 'Late twin');
      await searchTwins();
      await tap(find.text('до ${displayDate(late)}'));
      await waitFor(find.text('Late twin'));
      await tap(find.widgetWithText(FilledButton, 'Готово'));
      await showLesson(lesson);
      await diary();
      Future<void> toggle(bool done) async {
        await tap(find.text('Frame calculation'));
        await tap(find.text(
            done ? 'Отметить как выполнено' : 'Отметить как не выполнено'));
        await animate();
      }

      await toggle(true);
      await login(1);
      await diary();
      await toggle(true);
      await back();
      await diary();
      await toggle(false);
      await login(0);
      await diary();
      await tap(find.text('Frame calculation'));
      await waitFor(find.text('Отметить как не выполнено'));
      final assignment = await client
          .from('assignments')
          .select('id')
          .eq('title', 'Frame calculation')
          .single();
      final receipts = await client
          .from('assignment_done')
          .select('user_id')
          .eq('assignment_id', assignment['id']);
      expect(receipts.map((r) => r['user_id']), [accounts[0]['student']]);
      debugPrint(
          'E2E-078 PASS student B completing and undoing leaves student A completed');
      Future<void> notesFor(Lesson selected) async {
        await showLesson(selected);
        await tap(find.text('Добавить запись по предмету'));
        await waitFor(find.byTooltip('Добавить'));
      }

      const firstText = 'Разбор балки.\n\nM = F × l\nПроверено ✅';
      const secondText = 'Второе занятие: другой конспект';
      await notesFor(lesson);
      await tap(find.byTooltip('Добавить'));
      await tap(find.text('Заметка по предмету'));
      await noteText(firstText);
      await login(0);
      await notesFor(lesson);
      await waitFor(find.text(firstText));
      expect(
          (await entries
              .select('text')
              .eq('lesson_id', lesson.id)
              .single())['text'],
          firstText);
      debugPrint(
          'E2E-074 PASS multiline formula and emoji exactly preserved after login');
      await tap(find.text('Изменить'));
      await tester.enterText(field(hint: 'Текст заметки...'), '');
      await tap(find.text('Сохранить'));
      await waitFor(find.text('Пустой текст'));
      expect(
          (await entries
              .select('text')
              .eq('lesson_id', lesson.id)
              .single())['text'],
          firstText);
      debugPrint(
          'E2E-075 PASS empty edit shows reason and keeps original text on server');
      await tap(find.text('Отмена'));
      await notesFor(secondLesson);
      await waitFor(find.byTooltip('Добавить'));
      await tap(find.byTooltip('Добавить'));
      expect(find.text(firstText, skipOffstage: false), findsNothing,
          reason: 'Another lesson must not inherit the first lesson note');
      await tap(find.text('Заметка по предмету'));
      await noteText(secondText);
      for (final pair in [
        (lesson, firstText, secondText),
        (secondLesson, secondText, firstText)
      ]) {
        await notesFor(pair.$1);
        await waitFor(find.text(pair.$2));
        expect(find.text(pair.$3), findsNothing);
      }
      await showLesson(lesson);
      await diary();
      await tap(find.byIcon(Icons.more_horiz));
      await tap(find.text('Все заметки'));
      await waitFor(find.text(firstText));
      await waitFor(find.text(secondText));
      expect(
          (await entries
                  .select('lesson_id')
                  .eq('subject_offering_id', data['offering'])
                  .inFilter('text', [firstText, secondText]))
              .map((r) => r['lesson_id']),
          unorderedEquals([lesson.id, secondLesson.id]));
      debugPrint(
          'E2E-073 PASS separate notes for both lessons; both appear in the full diary');
      await showLesson(lesson);
      await diary();
      await tap(find.byIcon(Icons.add));
      await tap(find.text('Личная задача'));
      await tester.enterText(
          field(label: 'Название'), 'Slow task double submit');
      final create = find.text('Создать задачу');
      await tester.ensureVisible(create);
      final earlierPosts = httpClient.taskPosts;
      final gate = Completer<void>();
      httpClient.holdTask = gate;
      final submitAt = tester.getCenter(create);
      try {
        await tester.tapAt(submitAt);
        await tester.tapAt(submitAt);
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (httpClient.taskPosts == earlierPosts &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 70));
        }
        expect(httpClient.taskPosts - earlierPosts, 1,
            reason: 'Only one request may leave for a double tap');
      } finally {
        httpClient.holdTask = null;
        gate.complete();
      }
      final savedTask = find.text('Slow task double submit');
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (field(label: 'Название').evaluate().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(field(label: 'Название'), findsNothing,
          reason: 'Task form remained open after submit');
      await tester.enterText(
          field(hint: 'Поиск по дневнику предмета'), 'Slow task double submit');
      await animate();
      await waitFor(savedTask);
      await tester.ensureVisible(savedTask.last);
      expect(httpClient.taskPosts - earlierPosts, 1,
          reason: 'Exactly one HTTP request for double submit');
      expect(httpClient.taskResponses.last, 201,
          reason: 'Expected real PostgreSQL commit');
      expect(await tasks.select('id').eq('title', 'Slow task double submit'),
          hasLength(1));
      debugPrint(
          'E2E-076 PASS one personal task after two immediate taps on a delayed write');
      Future<void> calendarDay(DateTime date, String title) async {
        await tester.pumpWidget(MaterialApp(
            key: UniqueKey(),
            home: ScheduleScreen(now: () => date, subscribeRealtime: false)));
        await waitFor(find.text(title));
      }

      await calendarDay(lessonDay, 'Frame calculation');
      final teacherTransport = LocalSchemaHttpClient(data['restPort']);
      final teacher = SupabaseClient(localSupabaseUrl, data['anon'],
          httpClient: teacherTransport,
          postgrestOptions: PostgrestClientOptions(schema: schema),
          authOptions: const AuthClientOptions(autoRefreshToken: false));
      try {
        final actor = accounts[2];
        await teacher.auth.signInWithPassword(
            email: actor['email'], password: actor['password']);
        final moved = await teacher
            .from('assignments')
            .update({
              'due_at': lessonDay
                  .toUtc()
                  .add(const Duration(days: 2, hours: 12))
                  .toIso8601String()
            })
            .eq('id', assignment['id'])
            .select('id,created_by')
            .single();
        expect(moved['created_by'], actor['student']);
      } finally {
        await teacher.auth.signOut(scope: SignOutScope.local);
        await teacher.dispose();
        teacherTransport.close();
      }
      await calendarDay(lessonDay, 'Legacy practice');
      expect(find.text('Frame calculation'), findsNothing);
      await calendarDay(
          lessonDay.add(const Duration(days: 2)), 'Frame calculation');
      expect(find.text('Frame calculation'), findsOneWidget);
      await tap(find.text('Frame calculation'));
      await waitFor(find.byType(AssignmentDetailsScreen));
      expect(
          tester
              .widget<AssignmentDetailsScreen>(
                  find.byType(AssignmentDetailsScreen))
              .assignmentId,
          assignment['id']);
      await waitFor(find.text('Draw the support reactions'));
      debugPrint(
          'E2E-077 PASS same assignment opens from its rescheduled date after calendar reload');
      return;
    }
    if (data['planner'] == true) {
      final accounts = (data['accounts'] as List).cast<Map<String, dynamic>>();
      final tasks = client.from('personal_diary_tasks');
      final entries = client.from('subject_diary_entries');
      const checklist = 'Laboratory checklist';
      const ownerDescription = 'Support reactions: original calculations';
      const peerDescription = 'Peer sample measurements';
      const peerNote = 'Peer laboratory notebook';
      final search = field(hint: 'Поиск по дневнику предмета');

      Future<void> dismissSheet() async {
        await tester.tapAt(const Offset(5, 5));
        await animate();
      }

      Future<void> switchStudent(int index) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await animate();
        await client.auth.signOut();
        final account = accounts[index];
        final login = await client.auth.signInWithPassword(
            email: account['email'] as String,
            password: account['password'] as String);
        expect(login.user?.id, account['student']);
        await tester
            .pumpWidget(MaterialApp(home: LessonDetailsScreen(lesson: lesson)));
        await diary();
      }

      // Calendar month crossing and validation both happen in the actual form.
      await tap(find.byIcon(Icons.add));
      await tap(find.text('Личная задача'));
      await tap(find.text('Добавить дедлайн'));
      final picker = find.byType(DatePickerDialog);
      await waitFor(picker);
      final nextMonthLabel =
          MaterialLocalizations.of(tester.element(picker)).nextMonthTooltip;
      await tap(find.byTooltip(nextMonthLabel));
      final now = DateTime.now();
      final due = DateTime(now.year, now.month + 1, 5);
      await tap(find.descendant(of: picker, matching: find.text('5')));
      await tap(find.text('Выбрать'));
      await waitFor(find.text('Дедлайн: ${displayDate(due)}'));
      await tap(find.text('Создать задачу'));
      await waitFor(find.text('Введите название задачи'));
      expect(await tasks.select().eq('author_id', data['student'] as String),
          hasLength(1));
      const datedTitle = 'Submit monthly progress sheet';
      await tester.enterText(field(label: 'Название'), datedTitle);
      await tap(find.text('Создать задачу'));
      await waitFor(find.text(datedTitle));
      final dated = await tasks.select().eq('title', datedTitle).single();
      expect(dated['author_id'], accounts[0]['student']);
      expect(dated['subject_offering_id'], data['offering']);
      expect(displayDate(DateTime.parse(dated['due_at'] as String)),
          displayDate(due));
      await tap(find.text(datedTitle));
      await waitFor(find.text('до ${displayDate(due)}').hitTestable());
      await dismissSheet();
      debugPrint(
          'PLANNER PASS 1 corrected blank task retains next-month deadline on server and card');

      await tap(find.text(checklist));
      await waitFor(find.text(ownerDescription));
      await tap(find.widgetWithText(OutlinedButton, 'В работе'));
      await waitFor(find.text('В работе'));
      await back();
      await diary();
      final reopened = await tasks.select().eq('title', checklist).single();
      expect(reopened['status'], 'in_progress');
      expect(reopened['completed_at'], isNull);
      await waitFor(find.textContaining('2 личных активных'));
      debugPrint(
          'PLANNER PASS 2 resumed completed task and active count survive reopening');

      final ownerEntries = await entries
          .select('id,text,entry_date')
          .eq('subject_offering_id', data['offering'] as String)
          .order('id');
      await tap(find.byIcon(Icons.add));
      await tap(find.text('Заметка по предмету'));
      await tester.enterText(field(hint: 'Заметка...'), 'Discard this recap');
      await tap(find.text('Отмена'));
      await back();
      await diary();
      expect(
          await entries
              .select('id,text,entry_date')
              .eq('subject_offering_id', data['offering'] as String)
              .order('id'),
          ownerEntries);
      expect(find.text('Discard this recap'), findsNothing);
      debugPrint(
          'PLANNER PASS 3 discarded an unsaved note without replacing an existing entry');

      final otherRow = await entries
          .select()
          .eq('subject_offering_id', data['otherOffering'] as String)
          .single();
      expect(otherRow['author_id'], accounts[0]['student']);
      await tap(find.byIcon(Icons.more_horiz));
      await tap(find.text('Все заметки'));
      final list = find.byType(ListView);
      await waitFor(find.descendant(
          of: list, matching: find.text('Archive bridge sketch')));
      final firstNote = find.descendant(
          of: list, matching: find.text('Another lesson today'));
      final olderNote = find.descendant(
          of: list, matching: find.text('Archive bridge sketch'));
      expect(tester.getTopLeft(firstNote).dy,
          lessThan(tester.getTopLeft(olderNote).dy));
      expect(find.text(otherRow['text'] as String), findsNothing);
      expect(find.text(peerNote), findsNothing);
      await back();
      // A second same-titled offering must lead to the other notebook.
      Lesson withOtherOffering() => Lesson(
          id: data['lesson'] as String,
          date: lessonDay,
          week: 2,
          day: '',
          pairNum: 2,
          start: lesson.start,
          end: lesson.end,
          subjectRaw: 'E2E Mechanics',
          subjectOfferingId: data['otherOffering'] as String);
      await tester.pumpWidget(const SizedBox.shrink());
      await animate();
      await tester.pumpWidget(
          MaterialApp(home: LessonDetailsScreen(lesson: withOtherOffering())));
      await tap(find.text('Дневник предмета'));
      await tap(find.byIcon(Icons.more_horiz));
      await tap(find.text('Все заметки'));
      await waitFor(find.text(otherRow['text'] as String));
      expect(find.text('Archive bridge sketch'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await animate();
      await tester
          .pumpWidget(MaterialApp(home: LessonDetailsScreen(lesson: lesson)));
      await diary();
      debugPrint(
          'PLANNER PASS 4 both same-titled offerings open distinct date-ordered notebooks');

      await tester.enterText(search, 'SUPPORT REACTIONS');
      await animate();
      await waitFor(find.text('Frame calculation'));
      expect(find.text(checklist), findsOneWidget);
      expect(find.text(datedTitle), findsNothing);
      await tester.enterText(search, 'no_matching_lab_1729');
      await animate();
      await waitFor(find.text('Заданий по предмету пока нет.'));
      await tap(find.byIcon(Icons.close_rounded));
      await waitFor(find.text(datedTitle));
      expect(find.text(checklist), findsOneWidget);
      expect(find.text('Frame calculation'), findsOneWidget);
      debugPrint(
          'PLANNER PASS 6 search by description finds personal and group work, clearing restores both');

      Future<void> verifyOwnDiary(int index) async {
        final description = index == 0 ? ownerDescription : peerDescription;
        final note = index == 0 ? 'Another lesson today' : peerNote;
        final task = await tasks.select().eq('title', checklist).single();
        expect(task['author_id'], accounts[index]['student']);
        expect(task['description'], description);
        final noteRow =
            await entries.select('author_id').eq('text', note).single();
        expect(noteRow['author_id'], accounts[index]['student']);
        await tap(find.text(checklist));
        await waitFor(find.text(description));
        await waitFor(find.text(index == 0
            ? 'E2E Mechanics • В работе'
            : 'E2E Mechanics • Нужно сделать'));
        expect(find.text(index == 0 ? peerDescription : ownerDescription),
            findsNothing);
        await dismissSheet();
        await tap(find.byIcon(Icons.more_horiz));
        await tap(find.text('Все заметки'));
        await waitFor(find.text(note));
        expect(find.text(index == 0 ? peerNote : 'Another lesson today'),
            findsNothing);
        await back();
      }

      await switchStudent(1);
      await verifyOwnDiary(1);
      await switchStudent(0);
      await verifyOwnDiary(0);
      debugPrint(
          'PLANNER PASS 7 switched students and back; same title opens the correct task and notes');

      final assignment = await client
          .from('assignments')
          .select('id')
          .eq('title', 'Frame calculation')
          .single();
      final receipts = client.from('assignment_done');
      Future<void> verifySummaries(bool expectedDone,
          {bool legacyDone = false}) async {
        final diarySummary = await PersonalDiaryService(client: client).load();
        final schedule = await ScheduleRepository(client: client)
            .loadMonthAssignments(lessonDay);
        for (final title in ['Frame calculation', 'Legacy practice']) {
          final expected =
              title == 'Frame calculation' ? expectedDone : legacyDone;
          expect(
              diarySummary.publishedAssignments
                  .singleWhere((r) => r.title == title)
                  .completedByMe,
              expected,
              reason: 'Personal diary completion of $title');
          expect(
              schedule.singleWhere((r) => r.title == title).completed, expected,
              reason: 'Schedule completion of $title');
        }
      }

      await tap(find.text('Frame calculation'));
      await tap(find.text('Отметить как выполнено'));
      await waitFor(find.text('Выполнено'));
      await back();
      await diary();
      final completion = await receipts
          .select('user_id')
          .eq('assignment_id', assignment['id'])
          .single();
      expect(completion['user_id'], accounts[0]['student']);
      await tap(find.text('Frame calculation'));
      await waitFor(find.text('Отметить как не выполнено'));
      await dismissSheet();
      await verifySummaries(true);
      await switchStudent(1);
      await tap(find.text('Frame calculation'));
      await waitFor(find.text('Отметить как выполнено'));
      expect(
          await receipts
              .select()
              .eq('assignment_id', assignment['id'])
              .eq('user_id', accounts[1]['student'] as String),
          isEmpty);
      await dismissSheet();
      await verifySummaries(false);
      await switchStudent(0);
      await tap(find.text('Frame calculation'));
      await tap(find.text('Отметить как не выполнено'));
      await back();
      await diary();
      expect(await receipts.select().eq('assignment_id', assignment['id']),
          isEmpty);
      await verifySummaries(false);
      await tap(find.text('Frame calculation'));
      await waitFor(find.text('Отметить как выполнено'));
      await dismissSheet();
      await tap(find.text('Legacy practice'));
      await tap(find.text('Отметить как выполнено'));
      await back();
      await diary();
      await tap(find.text('Legacy practice'));
      await waitFor(find.text('Отметить как не выполнено'));
      await verifySummaries(false, legacyDone: true);
      await tap(find.text('Отметить как не выполнено'));
      await back();
      await diary();
      await verifySummaries(false);
      expect(tester.takeException(), isNull);
      debugPrint(
          'PLANNER PASS 5 group work completion persists only for its student and can be undone');
      return;
    }
    await tap(find.text('Frame calculation'));
    await waitFor(find.text('Draw the support reactions'));
    expect(find.text('до ${displayDate(lessonDay)}'), findsWidgets);
    await tester.tapAt(const Offset(8, 8));
    await animate();
    expect(find.text('Unpublished exercise'), findsNothing);
    debugPrint(
        'ACADEMIC PASS 1 published assignment details, due date, draft excluded');

    await tap(find.byIcon(Icons.add));
    await tap(find.text('Личная задача'));
    await tester.enterText(field(label: 'Название'), 'Check bending diagram');
    await tester.enterText(
        field(label: 'Описание, если нужно'), 'Verify section B');
    await tap(find.text('Создать задачу'));
    await waitFor(find.text('Check bending diagram'));
    final tasks = client.from('personal_diary_tasks');
    final saved =
        await tasks.select().eq('title', 'Check bending diagram').single();
    expect(saved['author_id'], data['student']);
    expect(saved['subject_offering_id'], data['offering']);
    expect(saved['description'], 'Verify section B');
    expect(saved['status'], 'todo');
    debugPrint(
        'ACADEMIC PASS 2 new private subject task committed to Postgres');

    await tap(find.text('Check bending diagram'));
    await tap(find.widgetWithText(FilledButton, 'Готово'));
    await waitFor(find.text('Готово'));
    final done = await tasks.select().eq('id', saved['id']).single();
    expect(done['status'], 'done');
    expect(done['completed_at'], isNotNull);
    await back();
    await diary();
    await waitFor(find.text('Готово'));
    expect(find.textContaining('0 личных активных'), findsOneWidget);
    debugPrint(
        'ACADEMIC PASS 3 completed task survives reopening and active count changes');

    await back();
    await tap(find.text('Добавить запись по предмету'));
    await tap(find.byTooltip('Добавить'));
    await tap(find.text('Заметка по предмету'));
    const lessonText = 'Lesson shear forces';
    await noteText(lessonText);
    final entries = client.from('subject_diary_entries');
    final linked = await entries.select().eq('text', lessonText).single();
    expect(linked['entry_date'], data['lessonDay']);
    expect(linked['lesson_id'], data['lesson']);
    expect(linked['subject_offering_id'], data['offering']);
    debugPrint(
        'ACADEMIC PASS 4 lesson note saved with the correct lesson, subject and date');
    await back();
    await diary();

    final search = field(hint: 'Поиск по дневнику предмета');
    await tester.enterText(search, 'ARCHIVE');
    await animate();
    await waitFor(find.text('Archive bridge sketch'));
    expect(find.text(lessonText), findsNothing);
    await tap(find.text('Archive bridge sketch'));
    await waitFor(find.text('Archive bridge sketch'));
    expect(find.text(displayDate(archiveDay)), findsWidgets);
    await back();
    await tester.enterText(search, '');
    await animate();
    debugPrint(
        'ACADEMIC PASS 5 search opens the matching archived day and note');

    await tap(find.byIcon(Icons.add));
    await tap(find.text('Заметка по предмету'));
    const todayText = 'Independent daily recap';
    await noteText(todayText);
    final records =
        await entries.select().eq('subject_offering_id', data['offering']);
    expect(
        records.where((r) =>
            r['id'] == linked['id'] &&
            r['text'] == lessonText &&
            r['entry_date'] == data['lessonDay'] &&
            r['lesson_id'] == data['lesson']),
        hasLength(1),
        reason: 'A different day must preserve the existing lesson note');
    expect(
        records.where((r) =>
            r['text'] == todayText &&
            r['entry_date'] == data['today'] &&
            r['lesson_id'] == null),
        hasLength(1));
    expect(records.where((r) => r['text'] == 'Archive bridge sketch'),
        hasLength(1));
    expect(
        records.where((r) =>
            r['text'] == 'Another lesson today' &&
            r['entry_date'] == data['today'] &&
            r['lesson_id'] != null),
        hasLength(1));
    await back();
    await diary();
    await tester.enterText(search, todayText);
    await animate();
    await waitFor(find.text(todayText));
    expect(tester.takeException(), isNull);
    debugPrint(
        'ACADEMIC PASS 6 a different day keeps its own note and the original lesson link');
  }, skip: fixture == null);
}
