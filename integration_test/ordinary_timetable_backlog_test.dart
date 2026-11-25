import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/info/subject_info_screen.dart';
import 'package:student_platform/src/ui/info/teacher_profile_screen.dart';
import 'package:student_platform/src/ui/info/useful_subjects_repository.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/learning_screen.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/widgets/lesson_card.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['STUDENT_TIMETABLE_LOCAL'];
  if (fixture == null) {
    test('requires disposable local timetable', () {}, skip: true);
    return;
  }
  final data = jsonDecode(fixture) as Map<String, dynamic>;
  late LocalSchemaHttpClient transport;
  late SupabaseClient client;
  final accounts = data['accounts'] as List;
  Future<void> signIn(int index) async {
    if (client.auth.currentUser != null)
      await client.auth.signOut(scope: SignOutScope.local);
    final a = accounts[index];
    final result = await client.auth
        .signInWithPassword(email: a['email'], password: a['password']);
    expect(result.user!.id, a['student']);
  }

  setUpAll(() async {
    expect(data['schema'], matches(RegExp(r'^e2e_timetable_[0-9a-f]{12}$')));
    expect(SupabaseConfig.url, localSupabaseUrl);
    SharedPreferences.setMockInitialValues({});
    transport = LocalSchemaHttpClient(data['restPort'] as int);
    await Supabase.initialize(
        url: localSupabaseUrl,
        publishableKey: data['anon'] as String,
        httpClient: transport,
        postgrestOptions:
            PostgrestClientOptions(schema: data['schema'] as String),
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
  Future<void> step(
      WidgetTester t, bool Function() ready, String reason) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (!ready() && DateTime.now().isBefore(end)) {
      await t.pump(const Duration(milliseconds: 80));
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<void> visible(WidgetTester t, String label) =>
      step(t, () => find.text(label).evaluate().isNotEmpty, label);
  Future<void> tap(WidgetTester t, Finder f) async {
    await step(t, () => f.evaluate().isNotEmpty, f.toString());
    await Scrollable.ensureVisible(t.element(f.first), alignment: .5);
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(f.hitTestable().first);
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 90));
    }
  }

  final december = DateTime(2026, 12, 28, 12),
      january = DateTime(2027, 1, 4, 12);
  Future<void> schedule(WidgetTester t, DateTime date, String? expected) async {
    await t.pumpWidget(MaterialApp(
        key: UniqueKey(),
        home: AuthSessionScopeHost(
            child: ScheduleScreen(now: () => date, subscribeRealtime: false))));
    if (expected != null) await visible(t, expected);
  }

  Finder cardByRoom(String room) =>
      find.ancestor(of: find.text(room), matching: find.byType(LessonCard));
  Future<LessonDetailsScreen> details(WidgetTester t, String room) async {
    final card = cardByRoom(room);
    await tap(t, card);
    await visible(t, 'Занятие');
    await visible(t, room);
    return t.widget<LessonDetailsScreen>(find.byType(LessonDetailsScreen));
  }

  Future<SubjectInfoScreen> subject(WidgetTester t) async {
    await tap(
        t, find.text('Краткая информация, материалы, чат и дневник предмета.'));
    await step(t, () => find.byType(SubjectInfoScreen).evaluate().isNotEmpty,
        'Subject info route is open');
    return t.widget<SubjectInfoScreen>(find.byType(SubjectInfoScreen));
  }

  Future<String> openSubjectTeam(WidgetTester t) async {
    final chatControl = find.text('Чат');
    await t.scrollUntilVisible(chatControl, 220,
        scrollable: find.byType(Scrollable).first);
    final action =
        find.ancestor(of: chatControl, matching: find.byType(InkWell)).first;
    await step(
        t,
        () =>
            action.evaluate().isNotEmpty &&
            t.widget<InkWell>(action).onTap != null,
        'Enabled chat shortcut');
    await tap(t, action);
    await step(t, () => find.byType(TeamDetailsScreen).evaluate().isNotEmpty,
        'Team route is open');
    final team =
        t.widget<TeamDetailsScreen>(find.byType(TeamDetailsScreen)).team;
    await visible(t, team.name);
    return team.id;
  }

  void journey(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      await signIn(0);
      try {
        await body(t);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await t.pump(const Duration(milliseconds: 400));
      }
    });
  }

  journey(
      '051 058 060 change weeks, keep course, open both campuses and cross year',
      (t) async {
    final clock = Stopwatch()..start();
    await schedule(t, december, 'North 10');
    debugPrint(
        'TIMING December timetable visible ${clock.elapsedMilliseconds} ms; local debug Windows');
    final first = await details(t, 'North 10');
    await visible(t, '09:00 – 10:30');
    expect(first.lesson.date.year, 2026);
    final firstSubject = await subject(t);
    expect(firstSubject.subjectOfferingId, data['off1']);
    final firstId = first.lesson.id;
    await schedule(t, december, 'South 20');
    final second = await details(t, 'South 20');
    await visible(t, '11:00 – 12:30');
    expect(second.lesson.id, isNot(firstId));
    expect(
        (await subject(t)).subjectOfferingId, firstSubject.subjectOfferingId);
    debugPrint('E2E-058 PASS times, rooms and distinct lesson links verified');
    await schedule(t, december, 'North 10');
    await tap(t, find.byTooltip('Следующая неделя'));
    await visible(t, 'North 99');
    final next = await details(t, 'North 99');
    expect(next.lesson.date.year, 2027);
    expect(next.lesson.date.month, 1);
    final nextSubject = await subject(t);
    expect(nextSubject.subjectOfferingId, firstSubject.subjectOfferingId);
    expect(nextSubject.semesterNumber, 3);
    expect(next.lesson.academicTermId, data['term']);
    expect(first.lesson.academicTermId, data['term']);
    final cards = await UsefulSubjectsRepository()
        .load(groupId: data['a'], currentSemester: 3);
    expect(
        cards
            .where((item) => item.title == 'Bridge mechanics')
            .map((item) => item.id),
        [data['off1']]);
    debugPrint(
        'E2E-060 PASS December to January via next-week and correct subject IDs and academic term');
    debugPrint(
        'E2E-051 same linked offering across both weeks; changed room in timetable');
  });
  journey(
      '053 054 case, nonbreaking space, and final word distinguish subjects',
      (t) async {
    await schedule(t, DateTime(2026, 12, 30, 12), 'West 40');
    await details(t, 'West 40');
    expect((await subject(t)).subjectOfferingId, data['off1']);
    final normalizedTeam = await openSubjectTeam(t);
    final expectedTeam = await client
        .from('teams')
        .select('id')
        .eq('subject_offering_id', data['off1'])
        .single();
    expect(normalizedTeam, expectedTeam['id']);
    final byVariant = await client
        .from('lessons')
        .select('subject,subject_offering_id,alias_match_status')
        .eq('room', 'West 40')
        .single();
    expect(byVariant['subject'], 'BRIDGE\u00a0  MECHANICS');
    expect(byVariant['alias_match_status'], 'matched');
    debugPrint(
        'E2E-053 normalized imported name opens the linked subject offering');
    await schedule(t, december, 'North 10');
    await details(t, 'North 10');
    final one = await subject(t);
    final firstTeam = await openSubjectTeam(t);
    await schedule(t, DateTime(2026, 12, 29, 12), 'East 30');
    await details(t, 'East 30');
    final two = await subject(t);
    expect(await openSubjectTeam(t), isNot(firstTeam));
    expect(one.subjectOfferingId, data['off1']);
    expect(two.subjectOfferingId, data['off2']);
    expect(two.subjectId, isNot(one.subjectId));
    debugPrint(
        'E2E-054 two similarly named disciplines open distinct subject cards');
  });
  journey('035 system back through next-week chat preserves selected date',
      (t) async {
    await schedule(t, december, 'North 10');
    await tap(t, find.byTooltip('Следующая неделя'));
    await visible(t, 'North 99');
    final selected = await details(t, 'North 99');
    expect(selected.lesson.date, DateTime(2027, 1, 4));
    await subject(t);
    await openSubjectTeam(t);
    await visible(t, 'Before academic plan');
    for (final screen in [
      SubjectInfoScreen,
      LessonDetailsScreen,
      ScheduleScreen
    ]) {
      await t.binding.handlePopRoute();
      await step(t, () => find.byType(screen).evaluate().isNotEmpty,
          'System back opened $screen');
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 90));
      }
    }
    await visible(t, 'North 99');
    expect(find.text('North 10'), findsNothing);
    final reopened = await details(t, 'North 99');
    expect(reopened.lesson.id, selected.lesson.id);
    expect(reopened.lesson.date, DateTime(2027, 1, 4));
    debugPrint(
        'E2E-035 PASS system back from next-week chat kept the selected week, date and lesson');
  });
  journey(
      '031 rename offering and open the same message from schedule and Teams',
      (t) async {
    await schedule(t, december, 'North 10');
    await details(t, 'North 10');
    await subject(t);
    final original = await openSubjectTeam(t);
    await visible(t, 'Before academic plan');
    await client.rpc('advance_fixture', params: {'p_action': 'rename'});
    try {
      await schedule(t, december, 'North 10');
      expect((await details(t, 'North 10')).lesson.subject,
          'Updated bridge mechanics');
      expect((await subject(t)).subjectOfferingId, data['off1']);
      expect(await openSubjectTeam(t), original);
      await visible(t, 'Before academic plan');
      await t.pumpWidget(
          MaterialApp(key: UniqueKey(), home: const LearningScreen()));
      await visible(t, 'Renamed mechanics team');
      await tap(t, find.text('Renamed mechanics team'));
      await visible(t, 'Before academic plan');
      expect(
          t.widget<TeamDetailsScreen>(find.byType(TeamDetailsScreen)).team.id,
          original);
      debugPrint(
          'E2E-031 PASS renamed discipline and team, schedule and active Teams list led to same UUID and message');
    } finally {
      await client.rpc('advance_fixture', params: {'p_action': 'reset_name'});
    }
  });
  journey('056 move one lesson and check both dates with the same identity',
      (t) async {
    final from = DateTime(2026, 12, 29, 12), to = DateTime(2026, 12, 27, 12);
    await schedule(t, from, 'East 30');
    final before = await details(t, 'East 30');
    final offering = (await subject(t)).subjectOfferingId;
    await client.rpc('advance_fixture', params: {'p_action': 'move'});
    await schedule(t, from, null);
    final old = await ScheduleRepository(client: client)
        .loadRange(from, days: 1, strict: true);
    expect(old, isEmpty);
    await visible(t, 'Здесь пока пусто');
    expect(find.text('East 30'), findsNothing);
    await schedule(t, to, 'East 30');
    final after = await details(t, 'East 30');
    expect(after.lesson.id, before.lesson.id);
    expect(after.lesson.date.day, 27);
    expect((await subject(t)).subjectOfferingId, offering);
    debugPrint(
        'E2E-056 PASS old date empty, same lesson and same subject on new date');
  });
  journey(
      '057 069 distinct instructors and votes after a one-lesson replacement',
      (t) async {
    Future<void> teacherProfile(String name) async {
      final teacher = find.text(name);
      await t.scrollUntilVisible(teacher, 220,
          scrollable: find.byType(Scrollable).first);
      await tap(
          t, find.ancestor(of: teacher, matching: find.byType(InkWell)).first);
      await visible(t, name);
      await step(
          t,
          () => find.byType(TeacherProfileScreen).evaluate().isNotEmpty,
          'Instructor profile is open');
    }

    await schedule(t, december, 'North 10');
    expect((await details(t, 'South 20')).lesson.teacher, 'Lecturer One');
    await teacherProfile('Lecturer One');
    final rate = find.widgetWithText(FilledButton, 'Оценить');
    await step(
        t,
        () =>
            rate.evaluate().isNotEmpty &&
            t.widget<FilledButton>(rate).onPressed != null,
        'Rating is ready');
    await tap(t, rate);
    await tap(t, find.byTooltip('4 из 5'));
    await visible(t, 'Моя оценка: 4');
    await client.rpc('advance_fixture', params: {'p_action': 'substitute'});
    await schedule(t, december, 'North 10');
    expect(
        (await details(t, 'South 20')).lesson.teacher, 'Replacement teacher');
    await visible(t, 'Replacement teacher');
    await teacherProfile('Replacement teacher');
    await visible(t, 'Сложность сдачи преподавателю пока не оценена');
    expect(find.text('Моя оценка: 4'), findsNothing);
    await schedule(t, december, 'North 10');
    expect((await details(t, 'North 10')).lesson.teacher, 'Lecturer One');
    await visible(t, 'Lecturer One');
    await teacherProfile('Lecturer One');
    await visible(t, 'Моя оценка: 4');
    await visible(t, '4.0 из 5 · 1 оценка');
    debugPrint(
        'E2E-069 PASS previous instructor retains vote, changed practice opens unrated replacement');
    debugPrint('E2E-057 PASS replacement applies only to the changed lesson');
  });
  journey(
      '055 preserve subject and team history when the official plan is assigned',
      (t) async {
    Future<void> openHistory() async {
      await schedule(t, december, 'North 10');
      await details(t, 'North 10');
      await subject(t);
      await openSubjectTeam(t);
      await visible(t, 'Before academic plan');
    }

    Future<void> countCards() async {
      final cards = await UsefulSubjectsRepository()
          .load(groupId: data['a'], currentSemester: 3);
      expect(
          cards
              .where((item) => item.title == 'Bridge mechanics')
              .map((item) => item.id),
          [data['off1']]);
    }

    final profile = await client
        .from('group_academic_profiles')
        .select('curriculum_plan_id')
        .eq('group_id', data['a'])
        .single();
    expect(profile['curriculum_plan_id'], isNull);
    await countCards();
    await openHistory();
    final previous =
        t.widget<TeamDetailsScreen>(find.byType(TeamDetailsScreen)).team.id;
    final staffTransport = LocalSchemaHttpClient(data['restPort']);
    final staff = SupabaseClient(localSupabaseUrl, data['anon'],
        httpClient: staffTransport,
        postgrestOptions: PostgrestClientOptions(schema: data['schema']),
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    try {
      final actor = accounts[2];
      await staff.auth.signInWithPassword(
          email: actor['email'], password: actor['password']);
      final assigned =
          await staff.rpc('admin_assign_group_curriculum_plan', params: {
        'p_group_id': data['a'],
        'p_curriculum_plan_id': data['plan'],
        'p_expected_plan_id': null
      });
      expect(assigned, data['plan']);
      await staff.rpc('confirm_test_offering');
    } finally {
      await staff.auth.signOut(scope: SignOutScope.local);
      await staff.dispose();
      staffTransport.close();
    }
    final linked = await client
        .from('group_academic_profiles')
        .select('curriculum_plan_id')
        .eq('group_id', data['a'])
        .single();
    expect(linked['curriculum_plan_id'], data['plan']);
    await countCards();
    await openHistory();
    expect(t.widget<TeamDetailsScreen>(find.byType(TeamDetailsScreen)).team.id,
        previous);
    debugPrint(
        'E2E-055 PASS official RPC assigned reviewed plan, one student course remains, existing chat history visible');
  });
  journey(
      '052 subgroup audience of the archived get_my_lessons is explicitly measured',
      (t) async {
    await client.rpc('advance_fixture', params: {'p_action': 'subgroup'});
    final date = DateTime(2026, 12, 31, 12);
    final own = await ScheduleRepository(client: client)
        .loadRange(date, days: 1, strict: true);
    await signIn(1);
    await schedule(t, date, 'Workshop');
    expect(
        (await details(t, 'Workshop')).lesson.subject, 'Subgroup B workshop');
    expect(own.map((l) => l.subject), isNot(contains('Subgroup B workshop')),
        reason: 'student A must not see a B-only lesson');
  });
  journey('059 transfer one student and compare the neighbour account',
      (t) async {
    await schedule(t, january, 'North 99');
    await details(t, 'North 99');
    expect((await subject(t)).subjectOfferingId, data['off1']);
    final originalTeam = await openSubjectTeam(t);
    await client.rpc('advance_fixture', params: {'p_action': 'new_group'});
    await schedule(t, january, 'New Group 11');
    await details(t, 'New Group 11');
    expect((await subject(t)).subjectOfferingId, data['off3']);
    expect(await openSubjectTeam(t), isNot(originalTeam));
    await signIn(1);
    await schedule(t, january, 'North 99');
    expect(find.text('New Group 11'), findsNothing);
    await details(t, 'North 99');
    expect((await subject(t)).subjectOfferingId, data['off1']);
    expect(await openSubjectTeam(t), originalTeam);
    debugPrint(
        'E2E-059 changed enrollment opens the new offering while peer keeps previous one');
  });
}
