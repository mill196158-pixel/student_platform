import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_prewarm.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'dart:convert';
import 'auth_session_scope_test.dart' show fakeSession;

Lesson lesson(DateTime date) => Lesson(id: 'lesson', date: date, week: 1, day: 'ПН',
  pairNum: 1, start: const TimeOfDay(hour: 9, minute: 0),
  end: const TimeOfDay(hour: 10, minute: 0), subjectRaw: 'Предмет');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('warm saves full months for the visible week for offline reader', () async {
    final session = fakeSession('a'), events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => scope.capture() != null);
    final calls = <int>[];
    final warm = SchedulePrewarm(scope: scope,
      cache: ScheduleMonthCache(scope, 'project'), barrier: barrier,
      loadMonth: (month) async { calls.add(month.month); return month.month == 11 ? [lesson(DateTime(2026, 11, 30))] : []; });
    await warm.warm(DateTime(2026, 11, 30));
    expect(calls, [11, 12]);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    final home = HomeSnapshotCache(project: 'project', authScope: scope,
      currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
      sessionIdentity: scope.capture);
    final reader = CachedHomeScheduleReader(capabilities: caps, home: home,
      schedule: ScheduleMonthCache(scope, 'project'));
    expect((await reader.readMonth(DateTime(2026, 11)))!.single.subjectRaw, 'Предмет');
    expect(await reader.readMonth(DateTime(2026, 12)), isEmpty);
    caps.dispose(); scope.dispose(); await events.close();
  });

  test('failed warm cannot invalidate a concurrent foreground write', () async {
    final session = fakeSession('a'), events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final foreground = ScheduleMonthCache(scope, 'project');
    final attempt = foreground.begin(DateTime(2026, 11))!;
    var calls = 0;
    final warm = SchedulePrewarm(scope: scope, cache: foreground,
      barrier: OnlineSideEffectBarrier(ownerIsCurrent: () => true),
      loadMonth: (_) async { calls++; throw StateError('offline'); });
    await warm.warm(DateTime(2026, 11, 5));
    expect(calls, 0);
    expect(await foreground.write(attempt, [lesson(DateTime(2026, 11, 5))]), isTrue);
    foreground.finishForeground(attempt);
    expect((await foreground.read(foreground.beginRead(DateTime(2026, 11))!))!.length, 1);
    scope.dispose(); await events.close();
  });

  test('successful warm updates an older completed foreground snapshot', () async {
    final session = fakeSession('a'), events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final cache = ScheduleMonthCache(scope, 'project'), month = DateTime(2026, 11);
    final foreground = cache.begin(month)!;
    expect(await cache.write(foreground, []), isTrue);
    cache.finishForeground(foreground);
    await SchedulePrewarm(scope: scope, cache: cache,
      barrier: OnlineSideEffectBarrier(ownerIsCurrent: () => true),
      loadMonth: (_) async => [lesson(DateTime(2026, 11, 5))]).warm(DateTime(2026, 11, 5));
    expect((await cache.read(cache.beginRead(month)!))!.single.subjectRaw, 'Предмет');
    scope.dispose(); await events.close();
  });

  test('new foreground attempt prevents older warm response replacing it', () async {
    final session = fakeSession('a'), events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final cache = ScheduleMonthCache(scope, 'project'), month = DateTime(2026, 11);
    final pending = Completer<List<Lesson>>();
    final warm = SchedulePrewarm(scope: scope, cache: cache,
      barrier: OnlineSideEffectBarrier(ownerIsCurrent: () => true),
      loadMonth: (_) => pending.future).warm(DateTime(2026, 11, 5));
    final foreground = cache.begin(month)!;
    expect(await cache.write(foreground, []), isTrue);
    cache.finishForeground(foreground);
    pending.complete([lesson(DateTime(2026, 11, 5))]);
    await warm;
    expect(await cache.read(cache.beginRead(month)!), isEmpty);
    scope.dispose(); await events.close();
  });
  test('new barrier does not reuse a cancelled older warmup', () async {
    final session = fakeSession('a'), events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final cache = ScheduleMonthCache(scope, 'project'), pending = Completer<List<Lesson>>();
    final oldBarrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    final old = SchedulePrewarm(scope: scope, cache: cache, barrier: oldBarrier,
      loadMonth: (_) => pending.future).warm(DateTime(2026, 11, 5));
    oldBarrier.close();
    var calls = 0;
    await SchedulePrewarm(scope: scope, cache: cache,
      barrier: OnlineSideEffectBarrier(ownerIsCurrent: () => true),
      loadMonth: (_) async { calls++; return [lesson(DateTime(2026, 11, 5))]; })
      .warm(DateTime(2026, 11, 5));
    expect(calls, 1);
    pending.complete([]);
    await old;
    expect((await cache.read(cache.beginRead(DateTime(2026, 11))!))!.single.subjectRaw, 'Предмет');
    scope.dispose(); await events.close();
  });

  test('late response after close or account switch is never saved', () async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = scope.capture()!;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => scope.isCurrent(owner));
    final pending = Completer<List<Lesson>>();
    final cache = ScheduleMonthCache(scope, 'project');
    final work = SchedulePrewarm(scope: scope, cache: cache, barrier: barrier,
      loadMonth: (_) => pending.future).warm(DateTime(2026, 11, 5));
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    barrier.close();
    pending.complete([lesson(DateTime(2026, 11, 5))]);
    await work;
    expect(await cache.read(cache.beginRead(DateTime(2026, 11))!), isNull);
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await cache.read(cache.beginRead(DateTime(2026, 11))!), isNull);
    scope.dispose(); await events.close();
  });

  test('revoked prewarm does not dispatch academic enrichment', () async {
    var current = true, calls = 0;
    final pending = Completer<http.Response>();
    http.Request? request;
    final client = SupabaseClient('https://example.invalid', 'test',
      httpClient: MockClient((value) { request = value; calls++; return pending.future; }));
    final repository = ScheduleRepository(client: client);
    final work = repository.loadMonthForPrewarm(DateTime(2026, 11), isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    current = false;
    pending.complete(http.Response(jsonEncode([{
      'id': 'lesson', 'date': '2026-11-05', 'week': 1, 'day': 'ЧТ',
      'pair_num': 1, 'time_start': '09:00', 'time_end': '10:00', 'subject': 'Предмет'
    }]), 200, headers: {'content-type': 'application/json'}, request: request));
    await expectLater(work, throwsStateError);
    expect(calls, 1);
    await client.dispose();
  });

  test('prewarm rejects a malformed server row rather than caching defaults', () async {
    final client = SupabaseClient('https://example.invalid', 'test',
      httpClient: MockClient((request) async => http.Response('[{"id":"x"}]', 200,
        headers: {'content-type': 'application/json'}, request: request)));
    await expectLater(ScheduleRepository(client: client).loadMonthForPrewarm(
      DateTime(2026, 11), isCurrent: () => true), throwsFormatException);
    await client.dispose();
  });
  test('prewarm accepts PostgreSQL time strings with seconds', () async {
    final client = SupabaseClient('https://example.invalid', 'test',
      httpClient: MockClient((request) async => http.Response(
        request.url.path.contains('/rpc/') ? jsonEncode([{
          'id': 'lesson', 'date': '2026-11-05', 'week': 1, 'day': 'ЧТ',
          'pair_num': 1, 'time_start': '09:00:00', 'time_end': '10:00:00', 'subject': 'Предмет'
        }]) : '[]', 200, headers: {'content-type': 'application/json'}, request: request)));
    final lessons = await ScheduleRepository(client: client).loadMonthForPrewarm(
      DateTime(2026, 11), isCurrent: () => true);
    expect(lessons.single.start.hour, 9);
    await client.dispose();
  });
}
