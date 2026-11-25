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

  Future<Lesson> bySubject(String title) async => Lesson.fromMap(
      await client.from('lessons').select().eq('subject', title).single());

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
    expect(accounts.map((a) => a['email']), [
      '$schema@student.local',
      '${schema}1@student.local',
      '${schema}2@student.local'
    ]);
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
    await client.auth.signOut(scope: SignOutScope.local);
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

  final phase = Platform.environment['STUDENT_QA_PHASE'];
  if (phase == 'first' || phase == 'second') {
    journey('068 two independently opened star pickers, session $phase',
        (j) async {
      final lesson = await j.bySubject('Информатика');
      final target = await client
          .from('teacher_difficulty_targets')
          .select('id')
          .eq('display_name', lesson.teacher!)
          .single();
      final sessions = client.from('test_rating_sessions');
      final votes = client.from('teacher_difficulty_votes');
      await j.open(lesson);
      await j.stars('Оценить');
      await sessions.insert({'phase': phase});
      Future<void> until(Future<bool> Function() ready) async {
        final end = DateTime.now().add(const Duration(minutes: 2));
        while (!await ready()) {
          if (DateTime.now().isAfter(end))
            fail('Other rating session did not reach its expected step');
          await j.tester.pump(const Duration(milliseconds: 150));
        }
      }

      await until(() async =>
          (await sessions.select('session_id'))
              .map((r) => r['session_id'])
              .toSet()
              .length ==
          2);
      Future<bool> saved(int score) async {
        final rows = await votes.select('score').eq('teacher_id', target['id']);
        return rows.length == 1 && rows.single['score'] == score;
      }

      if (phase == 'first') {
        await j.tap(find.byTooltip('2 из 5'));
        await j.visible('Моя оценка: 2');
        await sessions.update({'confirmed': true}).eq('phase', 'first');
      } else {
        await until(() async =>
            (await sessions
                .select('confirmed')
                .eq('phase', 'first')
                .single())['confirmed'] ==
            true);
        await until(() => saved(2));
        await j.tap(find.byTooltip('5 из 5'));
        await j.visible('Моя оценка: 5');
      }
      await until(() => saved(5));
      await j.open(lesson);
      await j.visible('Моя оценка: 5');
      await j.visible('5.0 из 5 · 1 оценка');
      debugPrint(
          'E2E-068 PASS session $phase: independently opened UI picker, final own score 5, exactly one vote');
    });
    return;
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
  if (jsonDecode(fixture)['legacy'] == true) return;
  journey('061 two lecturers with identical surnames keep independent votes',
      (j) async {
    for (final spec in [
      ('Геометрия', 'Орлов П.А.', 2),
      ('Гидравлика', 'Орлов П.В.', 4)
    ]) {
      await j.open(await j.bySubject(spec.$1));
      await j.visible(spec.$2);
      await j.visible(
          spec.$2 == 'Орлов П.А.' ? 'Кафедра геометрии' : 'Кафедра гидравлики');
      await j.vote('Оценить', spec.$3);
      await j.visible('Моя оценка: ${spec.$3}');
    }
    await j.open(await j.bySubject('Геометрия'));
    await j.visible('2.0 из 5 · 1 оценка');
    await j.visible('Моя оценка: 2');
  });
  journey(
      '062 063 different subjects share the vote of the exact hyphenated teacher',
      (j) async {
    const teacher = 'Семёнова-Орлова Л.И.';
    await j.open(await j.bySubject('Механика'));
    await j.visible(teacher);
    await j.vote('Оценить', 4);
    await j.visible('Моя оценка: 4');
    await j.open(await j.bySubject('Термодинамика'));
    await j.visible(teacher);
    await j.visible('Термодинамика');
    await j.visible('Моя оценка: 4');
    await j.visible('4.0 из 5 · 1 оценка');
  });
  journey(
      '065 open a teacher without a photo or department after a different profile',
      (j) async {
    await j.open(await j.bySubject('Геометрия'));
    await j.visible('Орлов П.А.');
    await j.visible('Кафедра геометрии');
    await j.open(await j.bySubject('Черчение'));
    await j.visible('Сидоров И.И.');
    expect(find.textContaining('Орлов'), findsNothing);
    expect(find.text('Кафедра геометрии'), findsNothing);
    expect(
        j.tester
            .widgetList<Image>(find.byType(Image))
            .where((i) => i.image is NetworkImage),
        isEmpty);
    expect(
        j.tester
            .widget<TeacherProfileScreen>(find.byType(TeacherProfileScreen))
            .department,
        isNull);
  });
  journey('067 tap a star twice before the confirmation animation finishes',
      (j) async {
    await j.open(await j.bySubject('Материаловедение'));
    await j.stars('Оценить');
    final star = find.byTooltip('3 из 5');
    final center = j.tester.getCenter(star);
    await j.tester.tapAt(center);
    await j.tester.tapAt(center);
    await j.visible('Моя оценка: 3');
    await j.tester.pumpWidget(const SizedBox.shrink());
    await signIn(1);
    await j.open(await j.bySubject('Материаловедение'));
    await j.visible('3.0 из 5 · 1 оценка');
    await j.stars('Оценить');
    await j.visible('Нажмите на звезду, чтобы сохранить оценку');
  });
  journey(
      '068 concurrent sessions of the same voter retain one last confirmed score',
      (j) async {
    final data = jsonDecode(fixture) as Map<String, dynamic>;
    final otherTransport = LocalSchemaHttpClient(data['restPort'] as int);
    final peer = SupabaseClient(localSupabaseUrl, data['anon'] as String,
        httpClient: otherTransport,
        postgrestOptions:
            PostgrestClientOptions(schema: data['schema'] as String),
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    try {
      final account = accounts.first;
      final peerSession = await peer.auth.signInWithPassword(
          email: account['email'], password: account['password']);
      expect(peerSession.user!.id, client.auth.currentUser!.id);
      expect(peerSession.session!.accessToken,
          isNot(client.auth.currentSession!.accessToken));
      final target = await peer
          .from('teacher_difficulty_targets')
          .select('id')
          .eq('display_name', 'Лебедева И.Н.')
          .single();
      expect(
          await peer
              .from('teacher_difficulty_votes')
              .select('score')
              .eq('teacher_id', target['id']),
          isEmpty);
      final lesson = await j.bySubject('Информатика');
      await j.open(lesson);
      await j.vote('Оценить', 2);
      await j.visible('Моя оценка: 2');
      await peer.from('teacher_difficulty_votes').upsert({
        'teacher_id': target['id'],
        'user_id': peer.auth.currentUser!.id,
        'score': 5
      });
      await j.open(lesson);
      await j.visible('Моя оценка: 5');
      await j.visible('5.0 из 5 · 1 оценка');
    } finally {
      await peer.auth.signOut(scope: SignOutScope.local);
      await peer.dispose();
      otherTransport.close();
    }
  });
  journey(
      '066 compare the rounded average and votes in lesson and teacher profile',
      (j) async {
    final lesson = await j.bySubject('Топография');
    await j.tester
        .pumpWidget(MaterialApp(home: LessonDetailsScreen(lesson: lesson)));
    final teacher = find.text(lesson.teacher!);
    await j.tester.scrollUntilVisible(teacher, 220,
        scrollable: find.byType(Scrollable).first);
    await j.visible('3.7 из 5 · 3 оценки');
    await j
        .tap(find.ancestor(of: teacher, matching: find.byType(InkWell)).first);
    await j.visible('Biography of ${lesson.teacher}');
    await j.visible('3.7 из 5 · 3 оценки');
    await j.visible('Моя оценка: 5');
  });
  journey(
      '070 two groups see a changed department and preserve the student rating',
      (j) async {
    final one = await j.bySubject('Гидрология'),
        two = await j.bySubject('Гидрогеология');
    expect(one.groupId, isNot(two.groupId));
    await j.open(one);
    await j.visible('Первая кафедра');
    await j.vote('Оценить', 4);
    await j.visible('Моя оценка: 4');
    await client.rpc('change_test_department');
    for (final lesson in [two, one]) {
      await j.open(lesson);
      await j.visible('Обновлённая кафедра');
      await j.visible('Моя оценка: 4');
      expect(find.text('Первая кафедра'), findsNothing);
    }
  });
}
