import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/models/schedule_group_action_event.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Repository extends ScheduleRepository {
  _Repository() : super(client: SupabaseClient('http://localhost:54321', 'test',
      authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final calls = <Completer<List<Lesson>>>[];
  @override
  Future<List<Lesson>> loadMonth(DateTime anchor, {bool strict = false}) {
    final call = Completer<List<Lesson>>();
    calls.add(call);
    return call.future;
  }
  @override
  Future<List<ScheduleAssignment>> loadMonthAssignments(DateTime anchor) async => [];
  @override
  Future<List<ScheduleGroupActionEvent>> loadMonthGroupActions(DateTime anchor) async => [];
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
