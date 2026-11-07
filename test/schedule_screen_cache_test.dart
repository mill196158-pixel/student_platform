import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/models/schedule_group_action_event.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/shared/student_section_headers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Repository extends ScheduleRepository {
  _Repository() : super(client: SupabaseClient('http://localhost:54321', 'test',
      authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final calls = <Completer<List<Lesson>>>[];
  final invalidations = ValueNotifier<(int, String?, String?)>((0, null, null));
  @override
  ValueListenable<(int, String?, String?)>? get groupActionsInvalidations => invalidations;
  List<ScheduleAssignment> assignmentResult = [];
  bool failAssignments = false;
  bool timeoutAssignments = false;
  bool denyAssignments = false;
  List<ScheduleGroupActionEvent> groupResult = [];
  bool failGroupActions = false;
  bool timeoutGroupActions = false;
  bool denyGroupActions = false;
  @override
  Future<List<Lesson>> loadMonth(DateTime anchor, {bool strict = false}) {
    final call = Completer<List<Lesson>>();
    calls.add(call);
    return call.future;
  }
  @override
  Future<List<ScheduleAssignment>> loadMonthAssignments(DateTime anchor,
      {bool strict = false}) async {
    if (failAssignments && strict) throw const SocketException('offline');
    if (timeoutAssignments && strict) throw TimeoutException('offline');
    if (denyAssignments && strict) throw StateError('server denied');
    return assignmentResult;
  }
  @override
  Future<List<ScheduleGroupActionEvent>> loadMonthGroupActions(DateTime anchor,
      {bool strict = false}) async {
    if (failGroupActions && strict) throw const SocketException('offline');
    if (timeoutGroupActions && strict) throw TimeoutException('offline');
    if (denyGroupActions && strict) throw StateError('server denied');
    return groupResult;
  }
}

class _PendingPreferences implements SharedPreferences {
  final entered = Completer<void>();
  final release = Completer<void>();
  final data = <String, String>{};
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    data[key] = value;
    return true;
  }
  @override
  Future<bool> remove(String key) async { data.remove(key); return true; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Lesson lesson(String id, DateTime date, String title) => Lesson(
  id: id, date: date, week: 1, day: 'ПН', pairNum: 1,
  start: const TimeOfDay(hour: 9, minute: 0),
  end: const TimeOfDay(hour: 10, minute: 30), subjectRaw: title);

void main() {
  for (final week in [false, true]) {
    testWidgets('invalidation fences group result waiting on lessons, week=$week', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = fakeSession('group-fence-$week');
      final events = StreamController<AuthState>.broadcast(sync: true);
      final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      final repo = _Repository();
      repo.groupResult = [ScheduleGroupActionEvent(eventType: 'collection_deadline',
          entityId: 'removed', title: 'Удалённый сбор', occursAt: DateTime(2026, 11, 5))];
      await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
          child: ScheduleScreen(repository: repo, subscribeRealtime: false,
              now: () => DateTime(2026, 11, 5)))));
      await tester.pump();
      repo.calls.first.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
      await tester.pumpAndSettle();
      expect(find.text('Удалённый сбор'), findsOneWidget);
      if (week) {
        tester.widget<StudentScheduleMenu>(find.byType(StudentScheduleMenu)).onSelected('view_week');
      } else {
        tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader)).onDatePicked(DateTime(2026, 11, 5));
      }
      await tester.pump(); await tester.pump();
      repo.invalidations.value = (1, 'collection', 'removed');
      await tester.pump();
      repo.calls.last.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
      await tester.pumpAndSettle();
      expect(find.text('Удалённый сбор'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await events.close();
    });
  }
  testWidgets('same-month offline reload retains assignments but account switch clears them', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var session = fakeSession('schedule-owner-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final repo = _Repository();
    repo.assignmentResult = [ScheduleAssignment(id: 'task', title: 'Локальное задание',
      description: '', dueAt: DateTime(2026, 11, 5),
      team: const Team(id: 'team', name: 'Команда', teacher: '', groupCode: '', icon: ''))];
    repo.groupResult = [
      ScheduleGroupActionEvent(eventType: 'collection_deadline', entityId: 'collection',
        title: 'Локальный сбор', occursAt: DateTime(2026, 11, 5)),
      ScheduleGroupActionEvent(eventType: 'collection_deadline', entityId: 'other',
        title: 'Другой сбор', occursAt: DateTime(2026, 11, 5)),
    ];
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: ScheduleScreen(repository: repo, subscribeRealtime: false,
          now: () => DateTime(2026, 11, 5)))));
    await tester.pump();
    repo.calls.first.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsOneWidget);
    expect(find.text('Локальный сбор'), findsOneWidget);
    repo.invalidations.value = (1, 'collection', 'collection');
    await tester.pump();
    expect(find.text('Локальный сбор'), findsNothing);
    expect(find.text('Другой сбор'), findsOneWidget);
    expect(find.text('Локальное задание'), findsOneWidget);
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump(); await tester.pump();
    repo.calls.last.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
    await tester.pumpAndSettle();
    expect(find.text('Локальный сбор'), findsOneWidget);
    repo.failAssignments = true;
    repo.failGroupActions = true;
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump();
    await tester.pump();
    expect(find.text('Локальное задание'), findsOneWidget);
    expect(find.text('Локальный сбор'), findsOneWidget);
    repo.calls.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsOneWidget);
    expect(find.text('Локальный сбор'), findsOneWidget);
    repo.failAssignments = false;
    repo.failGroupActions = false;
    repo.timeoutAssignments = true;
    repo.timeoutGroupActions = true;
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump(); await tester.pump();
    repo.calls.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsOneWidget);
    expect(find.text('Локальный сбор'), findsOneWidget);
    repo.timeoutAssignments = false;
    repo.timeoutGroupActions = false;
    repo.denyAssignments = true;
    repo.denyGroupActions = true;
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump(); await tester.pump();
    repo.calls.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsNothing);
    expect(find.text('Локальный сбор'), findsNothing);
    repo.denyAssignments = false;
    repo.denyGroupActions = false;
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump(); await tester.pump();
    repo.calls.last.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsOneWidget);
    expect(find.text('Локальный сбор'), findsOneWidget);
    final savedAssignments = repo.assignmentResult;
    final savedGroups = repo.groupResult;
    repo.assignmentResult = [];
    repo.groupResult = [];
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump(); await tester.pump();
    repo.calls.last.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsNothing);
    expect(find.text('Локальный сбор'), findsNothing);
    repo.assignmentResult = savedAssignments;
    repo.groupResult = savedGroups;
    tester.widget<StudentScheduleHeader>(find.byType(StudentScheduleHeader))
        .onDatePicked(DateTime(2026, 11, 5));
    await tester.pump(); await tester.pump();
    repo.calls.last.complete([lesson('live', DateTime(2026, 11, 5), 'Пара')]);
    await tester.pumpAndSettle();
    expect(find.text('Локальное задание'), findsOneWidget);
    expect(find.text('Локальный сбор'), findsOneWidget);
    session = fakeSession('schedule-owner-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(find.text('Локальное задание'), findsNothing);
    expect(find.text('Локальный сбор'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await events.close();
  });
  testWidgets('stalled preference lookup does not prevent live schedule', (tester) async {
    final session = fakeSession('schedule-prefs-screen');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final gate = Completer<SharedPreferences>();
    final repo = _Repository();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: ScheduleScreen(repository: repo, subscribeRealtime: false,
          cacheFactory: (s) => ScheduleMonthCache(s, SupabaseConfig.url, preferences: () => gate.future),
          now: () => DateTime(2026, 11, 5)))));
    await tester.pump();
    expect(repo.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(repo.calls, hasLength(1));
    repo.calls.first.complete([lesson('live', DateTime(2026, 11, 5), 'Свежая пара')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Свежая пара'), findsOneWidget);
    final prefs = _PendingPreferences();
    prefs.release.complete();
    gate.complete(prefs);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await events.close();
  });
  testWidgets('stalled cache plus network failure is unavailable, not empty', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = fakeSession('schedule-stalled-offline-test');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final prefs = _PendingPreferences();
    final cache = ScheduleMonthCache(scope, SupabaseConfig.url, preferences: () async => prefs);
    final writing = cache.write(cache.begin(DateTime(2026, 11))!, []);
    await prefs.entered.future;
    final repo = _Repository();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: ScheduleScreen(repository: repo, subscribeRealtime: false,
          now: () => DateTime(2026, 11, 5)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(repo.calls, hasLength(1));
    repo.calls.first.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Не удалось загрузить расписание. Подключитесь к сети и повторите.'), findsOneWidget);
    prefs.release.complete();
    expect(await writing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await events.close();
  });
  testWidgets('stalled cache write does not prevent live schedule', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = fakeSession('schedule-stalled-test');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final prefs = _PendingPreferences();
    final cache = ScheduleMonthCache(scope, SupabaseConfig.url, preferences: () async => prefs);
    final writing = cache.write(cache.begin(DateTime(2026, 11))!, []);
    await prefs.entered.future;
    final repo = _Repository();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: ScheduleScreen(repository: repo, subscribeRealtime: false,
          now: () => DateTime(2026, 11, 5)))));
    await tester.pump();
    expect(repo.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(repo.calls, hasLength(1));
    repo.calls.first.complete([lesson('live', DateTime(2026, 11, 5), 'Живое расписание')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Живое расписание'), findsOneWidget);
    prefs.release.complete();
    expect(await writing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await events.close();
  });
  testWidgets('disposing a pending screen releases foreground reservation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = fakeSession('schedule-screen-release');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final repo = _Repository(), cache = ScheduleMonthCache(scope, SupabaseConfig.url);
    Widget host(Widget child) => MaterialApp(home: AuthSessionScopeHost(
      key: const ValueKey('scope'), createScope: () => scope, child: child));
    await tester.pumpWidget(host(ScheduleScreen(repository: repo,
      subscribeRealtime: false, now: () => DateTime(2026, 11, 5))));
    await tester.pump();
    await tester.pump();
    expect(repo.calls, hasLength(1));
    expect(cache.beginBackground(DateTime(2026, 11)), isNull);
    await tester.pumpWidget(host(const SizedBox.shrink()));
    expect(cache.beginBackground(DateTime(2026, 11)), isNotNull);
    repo.calls.first.complete([lesson('late', DateTime(2026, 11, 5), 'Позднее')]);
    await tester.pump();
    expect(await cache.read(cache.beginRead(DateTime(2026, 11))!), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await events.close();
  });
  testWidgets('screen shows both cached months, ignores old request and clears on account change', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var session = fakeSession('schedule-screen-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final cache = ScheduleMonthCache(scope, SupabaseConfig.url);
    expect(await cache.write(cache.begin(DateTime(2026, 11))!,
      [lesson('nov', DateTime(2026, 11, 30), 'Ноябрьский предмет')]), isTrue);
    expect(await cache.write(cache.begin(DateTime(2026, 12))!,
      [lesson('dec', DateTime(2026, 12, 1), 'Декабрьский предмет')]), isTrue);
    final repo = _Repository();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: ScheduleScreen(repository: repo, subscribeRealtime: false,
          now: () => DateTime(2026, 11, 30, 12)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Ноябрьский предмет'), findsOneWidget);
    expect(repo.calls.length, 1);
    await tester.tap(find.byTooltip('Действия с расписанием'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По неделям'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ноябрьский предмет'), findsOneWidget);
    expect(find.text('Декабрьский предмет'), findsOneWidget);
    repo.calls.first.complete([lesson('late', DateTime(2026, 11, 30), 'Старый ответ')]);
    await tester.pump();
    expect(find.text('Старый ответ'), findsNothing);
    session = fakeSession('schedule-screen-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Ноябрьский предмет'), findsNothing);
    expect(find.text('Декабрьский предмет'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
