import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _local = 'http://127.0.0.1:55321';

// Keep GoTrue on its normal local API. Route PostgREST to this run's isolated
// server so other native E2Es can use their own schemas at the same time.
class _LocalAcademicClient extends http.BaseClient {
  _LocalAcademicClient(this.port);
  final int port;
  final _client = IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _local) throw StateError('Non-local host');
    const prefix = '/rest/v1';
    if (!request.url.path.startsWith('$prefix/')) return _client.send(request);
    final uri = request.url
        .replace(port: port, path: request.url.path.substring(prefix.length));
    final forwarded = http.Request(request.method, uri)
      ..followRedirects = false
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    return _client.send(forwarded);
  }

  @override
  void close() => _client.close();
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
    expect(SupabaseConfig.url, _local);
    tester.testTextInput.register();
    SharedPreferences.setMockInitialValues({});
    final httpClient = _LocalAcademicClient(data['restPort'] as int);
    await Supabase.initialize(
      url: _local,
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
    expect(records.where((r) => r['text'] == 'Another lesson today' &&
        r['entry_date'] == data['today'] && r['lesson_id'] != null), hasLength(1));
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
