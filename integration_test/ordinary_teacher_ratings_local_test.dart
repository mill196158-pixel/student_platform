import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/info/teacher_profile_screen.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

class _TeacherTransport extends LocalSchemaHttpClient {
  _TeacherTransport(super.port);
  bool failNextVote = false;
  bool offline = false;
  int refusedReads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.startsWith('/rest/v1/')) {
      if (offline) {
        if (request.method == 'GET') refusedReads++;
        throw const SocketException('Test timetable connection unavailable');
      }
      if (failNextVote &&
          request.method == 'POST' &&
          request.url.path.endsWith('/teacher_difficulty_votes')) {
        failNextVote = false;
        return http.StreamedResponse(
            Stream.value(utf8.encode('{"message":"Temporary outage"}')), 503,
            headers: {'content-type': 'application/json'});
      }
    }
    return super.send(request);
  }
}

class _TeacherJourney {
  _TeacherJourney(this.tester, this.client);
  final WidgetTester tester;
  final SupabaseClient client;

  Future<void> wait(bool Function() ready, String description) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (!ready() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 70));
    }
    expect(ready(), isTrue, reason: description);
  }

  Future<void> visible(String label) =>
      wait(() => find.text(label).evaluate().isNotEmpty, label);

  Future<void> tap(Finder target) async {
    await wait(() => target.evaluate().isNotEmpty, target.toString());
    await Scrollable.ensureVisible(tester.element(target.first), alignment: .5);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsWidgets,
        reason: 'Unreachable $target with bounds '
            '${tester.getRect(target.first)} in ${tester.getRect(find.byType(Scaffold).last)}');
    await tester.tap(target.hitTestable().first);
    await tester.pumpAndSettle();
  }

  Future<Lesson> lesson(int number) async {
    final row = await client
        .from('lessons')
        .select()
        .eq('teacher', 'Lecturer $number')
        .single();
    return Lesson.fromMap(row);
  }

  Future<void> open(Lesson lesson) async {
    await tester.pumpWidget(MaterialApp(
        key: UniqueKey(), home: LessonDetailsScreen(lesson: lesson)));
    await visible('Занятие');
    final screen = find.byType(Scaffold);
    expect(tester.getSize(screen).width,
        closeTo(MediaQuery.sizeOf(tester.element(screen)).width, 1),
        reason:
            'Exercise the real Windows viewport used for the lesson gutters');
    final teacher = find.text(lesson.teacher!);
    await tester.scrollUntilVisible(teacher, 220,
        scrollable: find.byType(Scrollable).first);
    await tap(find.ancestor(of: teacher, matching: find.byType(InkWell)).first);
    await visible('Biography of ${lesson.teacher}');
    await wait(() => find.byType(TeacherProfileScreen).evaluate().isNotEmpty,
        'Lesson did not open the teacher profile');
  }

  Future<void> stars(String button) async {
    final control = find.widgetWithText(FilledButton, button);
    await wait(
        () =>
            control.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(control).onPressed != null,
        'Enabled $button');
    await tap(control);
    await visible('Сложность сдачи преподавателю');
  }

  Future<void> vote(String button, int score) async {
    await stars(button);
    await tap(find.byTooltip('$score из 5'));
  }

  Future<void> server(int number,
      {required int votes, required int total, int? own}) async {
    final target = await client
        .from('teacher_difficulty_targets')
        .select('id')
        .eq('display_name', 'Lecturer $number')
        .single();
    final summary = await client
        .from('teacher_difficulty_summaries')
        .select('vote_count,score_total')
        .eq('teacher_id', target['id'])
        .single();
    expect(summary, {'vote_count': votes, 'score_total': total});
    final rows = await client
        .from('teacher_difficulty_votes')
        .select('user_id,score')
        .eq('teacher_id', target['id'])
        .eq('user_id', client.auth.currentUser!.id);
    expect(
        rows,
        own == null
            ? isEmpty
            : equals([
                {'user_id': client.auth.currentUser!.id, 'score': own}
              ]));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['STUDENT_TEACHER_LOCAL'];
  if (fixture == null) {
    test('requires two local students and a private teacher schema', () {},
        skip: true);
    return;
  }
  late SupabaseClient client;
  late _TeacherTransport transport;
  late List<dynamic> accounts;
  Future<void> signIn(int n) async {
    if (client.auth.currentUser != null) await client.auth.signOut();
    final account = accounts[n];
    final result = await client.auth.signInWithPassword(
        email: account['email'] as String,
        password: account['password'] as String);
    expect(result.user?.id, account['student']);
  }

  setUpAll(() async {
    final data = jsonDecode(fixture) as Map<String, dynamic>;
    final schema = data['schema'] as String;
    expect(schema, matches(RegExp(r'^e2e_teachers_[0-9a-f]{12}$')));
    expect(SupabaseConfig.url, localSupabaseUrl);
    accounts = data['accounts'] as List;
    expect(accounts.map((a) => a['email']),
        ['$schema@student.local', '${schema}1@student.local']);
    transport = _TeacherTransport(data['restPort'] as int);
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: localSupabaseUrl,
        publishableKey: data['anon'] as String,
        httpClient: transport,
        postgrestOptions: PostgrestClientOptions(schema: schema),
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage()));
    client = Supabase.instance.client;
  });
  tearDownAll(() async {
    await client.auth.signOut();
    await Supabase.instance.dispose();
    transport.close();
  });
  void journey(String name, Future<void> Function(_TeacherJourney) act) {
    testWidgets(name, (tester) async {
      await signIn(0);
      try {
        await act(_TeacherJourney(tester, client));
        expect(tester.takeException(), isNull);
      } finally {
        transport.offline = false;
        transport.failNextVote = false;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  journey('T1 same subject opens the teacher assigned to each lesson',
      (j) async {
    for (final n in [1, 2]) {
      await j.open(await j.lesson(n));
      await j.visible('Applied mechanics');
      await j.visible('3-й семестр');
      expect(find.text('Biography of Lecturer ${3 - n}'), findsNothing);
      await j.tap(find.byIcon(Icons.arrow_back_rounded));
      await j.visible('Занятие');
    }
  });
  journey('T2 dismiss the star picker and leave the teacher unrated',
      (j) async {
    await j.open(await j.lesson(3));
    await j.stars('Оценить');
    await j.tap(find.byTooltip('Закрыть без оценки'));
    await j.visible('Сложность сдачи преподавателю пока не оценена');
    await j.server(3, votes: 0, total: 0);
  });
  journey('T3 correct a rating and reopen without counting a second vote',
      (j) async {
    final lesson = await j.lesson(4);
    await j.open(lesson);
    await j.vote('Оценить', 2);
    await j.visible('Моя оценка: 2');
    await j.vote('Моя оценка: 2', 5);
    await j.visible('5.0 из 5 · 1 оценка');
    await j.open(lesson);
    await j.visible('Моя оценка: 5');
    await j.server(4, votes: 1, total: 5, own: 5);
  });
  journey('T4 two students see the same average and their own stars',
      (j) async {
    final lesson = await j.lesson(5);
    await j.open(lesson);
    await j.vote('Оценить', 1);
    await j.visible('Моя оценка: 1');
    await j.tester.pumpWidget(const SizedBox.shrink());
    await signIn(1);
    await j.open(lesson);
    await j.visible('1.0 из 5 · 1 оценка');
    await j.vote('Оценить', 4);
    await j.visible('2.5 из 5 · 2 оценки');
    await j.server(5, votes: 2, total: 5, own: 4);
    await j.tester.pumpWidget(const SizedBox.shrink());
    await signIn(0);
    await j.open(lesson);
    await j.visible('2.5 из 5 · 2 оценки');
    await j.stars('Моя оценка: 1');
    await j.visible('Текущая оценка: 1 из 5');
    await j.server(5, votes: 2, total: 5, own: 1);
  });
  journey('T5 retry a failed rating after checking it was not committed',
      (j) async {
    await j.open(await j.lesson(6));
    transport.failNextVote = true;
    await j.vote('Оценить', 3);
    await j.visible('Не удалось сохранить оценку');
    await j.server(6, votes: 0, total: 0);
    await j.vote('Оценить', 3);
    await j.visible('3.0 из 5 · 1 оценка');
    await j.server(6, votes: 1, total: 3, own: 3);
  });
  journey(
      'T6 reopen a previously rated profile without a working data connection',
      (j) async {
    final lesson = await j.lesson(7);
    await j.open(lesson);
    await j.vote('Оценить', 4);
    await j.visible('Моя оценка: 4');
    final before = transport.refusedReads;
    transport.offline = true;
    await j.open(lesson);
    await j.wait(
        () => transport.refusedReads > before, 'No failed online refresh');
    await j.visible('4.0 из 5 · 1 оценка');
    await j.stars('Моя оценка: 4');
    await j.visible('Текущая оценка: 4 из 5');
    transport.offline = false;
    await j.server(7, votes: 1, total: 4, own: 4);
  });
}
