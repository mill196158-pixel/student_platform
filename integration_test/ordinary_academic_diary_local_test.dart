import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/data/personal_diary_service.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

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
    final httpClient = LocalSchemaHttpClient(data['restPort'] as int);
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
