import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reads only owner snapshots and keeps empty distinct from missing',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final home = HomeSnapshotCache(
        project: 'test-project',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final schedule = ScheduleMonthCache(scope, 'test-project');
    final month = DateTime(2026, 11);
    expect(
        await home.write(
            scope: home.captureScope('a')!,
            section: HomeSnapshotSection.schedule,
            items: [],
            savedAt: DateTime.utc(2026)),
        isTrue);
    expect(await schedule.write(schedule.begin(month)!, []), isTrue);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final reader = CachedHomeScheduleReader(
        capabilities: capabilities, home: home, schedule: schedule);
    expect(
        (await reader.readHome(HomeSnapshotSection.schedule))!.items, isEmpty);
    expect(await reader.readHome(HomeSnapshotSection.profile), isNull);
    expect(await reader.readMonth(month), isEmpty);
    expect(await reader.readMonth(DateTime(2026, 12)), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect(capabilities.capture(SessionCapability.background), isNull);
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await expectLater(reader.readHome(HomeSnapshotSection.schedule),
        throwsA(isA<CachedHomeAccessDenied>()));
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('a revoked permit cannot publish a late cache read', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final pending = Completer<SharedPreferences>();
    final home = HomeSnapshotCache(
        project: 'test-project',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken,
        preferences: () => pending.future);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final reader = CachedHomeScheduleReader(
        capabilities: capabilities,
        home: home,
        schedule: ScheduleMonthCache(scope, 'test-project'));
    final read = reader.readHome(HomeSnapshotSection.schedule);
    final rejected = expectLater(read, throwsA(isA<CachedHomeAccessDenied>()));
    capabilities.block();
    pending.complete(await SharedPreferences.getInstance());
    await rejected;
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('stalled preferences do not hold the offline dashboard indefinitely', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('stalled-home');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final pending = Completer<SharedPreferences>();
    final home = HomeSnapshotCache(project: 'test-project', authScope: scope,
        currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken, preferences: () => pending.future);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final reader = CachedHomeScheduleReader(capabilities: capabilities, home: home,
        schedule: ScheduleMonthCache(scope, 'test-project'));
    var refreshes = 0;
    reader.refreshChanges.addListener(() => refreshes++);
    final data = await reader.readDashboard().timeout(const Duration(seconds: 3));
    expect(data.assignmentsStatus, 'Сохранённые задания временно недоступны');
    expect(data.scheduleStatus, 'Сохранённое расписание временно недоступно');
    pending.complete(await SharedPreferences.getInstance());
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, greaterThan(0));
    capabilities.dispose(); scope.dispose(); await events.close();
  });

  test('late cached read does not refresh a switched account', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('late-owner-a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final pending = Completer<SharedPreferences>();
    final home = HomeSnapshotCache(project: 'test-project', authScope: scope,
        currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken, preferences: () => pending.future);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final reader = CachedHomeScheduleReader(capabilities: capabilities, home: home,
        schedule: ScheduleMonthCache(scope, 'test-project'));
    var refreshes = 0;
    reader.refreshChanges.addListener(() => refreshes++);
    await expectLater(reader.readHome(HomeSnapshotSection.profile),
        throwsA(isA<CachedHomeTemporarilyUnavailable>()));
    session = fakeSession('late-owner-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    pending.complete(await SharedPreferences.getInstance());
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 0);
    capabilities.dispose(); scope.dispose(); await events.close();
  });

  test('late local read is consumed once instead of causing a retry loop', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('slow-once');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final prefs = await SharedPreferences.getInstance();
    var reads = 0;
    Future<SharedPreferences> slow() async {
      reads++;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return prefs;
    }
    final home = HomeSnapshotCache(project: 'test-project', authScope: scope,
        currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken, preferences: slow);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final reader = CachedHomeScheduleReader(capabilities: capabilities, home: home,
        schedule: ScheduleMonthCache(scope, 'test-project'));
    var refreshes = 0;
    reader.refreshChanges.addListener(() => refreshes++);
    await expectLater(reader.readHome(HomeSnapshotSection.profile),
        throwsA(isA<CachedHomeTemporarilyUnavailable>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(refreshes, 1);
    expect(await reader.readHome(HomeSnapshotSection.profile), isNull);
    expect(reads, 1, reason: 'late null is consumed without another slow read');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(refreshes, 1);
    capabilities.dispose(); scope.dispose(); await events.close();
  });

  test('staggered late sections never repeatedly reload each other', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('staggered');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    final prefs = await SharedPreferences.getInstance();
    final gates = List.generate(3, (_) => Completer<SharedPreferences>());
    var reads = 0;
    final home = HomeSnapshotCache(project: 'test-project', authScope: scope,
        currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken,
        preferences: () { final index = reads++; return gates[index].future; });
    final reader = CachedHomeScheduleReader(capabilities: caps, home: home,
        schedule: ScheduleMonthCache(scope, 'test-project'));
    await reader.readDashboard();
    expect(reads, 3);
    gates[0].complete(prefs); await Future<void>.delayed(Duration.zero);
    await reader.readDashboard();
    expect(reads, 3);
    gates[1].complete(prefs); await Future<void>.delayed(Duration.zero);
    await reader.readDashboard();
    expect(reads, 3);
    gates[2].complete(prefs); await Future<void>.delayed(Duration.zero);
    final finalData = await reader.readDashboard();
    expect(finalData.assignmentsStatus, 'Задания ещё не сохранены');
    expect(reads, 3);
    caps.dispose(); scope.dispose(); await events.close();
  });

  test('late month data is retried without rereading storage', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('slow-month');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final prefs = await SharedPreferences.getInstance();
    final month = DateTime(2026, 11);
    final writer = ScheduleMonthCache(scope, 'test-project', preferences: () async => prefs);
    final writeAttempt = writer.begin(month)!;
    expect(await writer.write(writeAttempt, []), isTrue);
    writer.finishForeground(writeAttempt);
    final gate = Completer<SharedPreferences>();
    var reads = 0;
    final schedule = ScheduleMonthCache(scope, 'test-project', preferences: () { reads++; return gate.future; });
    final home = HomeSnapshotCache(project: 'test-project', authScope: scope,
        currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final capabilities = SessionCapabilities(scope);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final reader = CachedHomeScheduleReader(capabilities: capabilities, home: home, schedule: schedule);
    var refreshes = 0;
    CachedHomeScheduleReader.scheduleRefreshFor(reader)!.addListener(() => refreshes++);
    await expectLater(reader.readMonth(month), throwsA(isA<CachedHomeTemporarilyUnavailable>()));
    gate.complete(prefs);
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 1);
    expect(await reader.readMonth(month), isEmpty);
    expect(reads, 1);
    capabilities.dispose(); scope.dispose(); await events.close();
  });

  test('home and schedule consume delayed month independently', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('split-month');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    var reads = 0;
    final schedule = ScheduleMonthCache(scope, 'test-project', preferences: () { reads++; return gate.future; });
    final home = HomeSnapshotCache(project: 'test-project', authScope: scope,
        currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final reader = CachedHomeScheduleReader(capabilities: caps, home: home, schedule: schedule);
    var homeNotifications = 0, scheduleNotifications = 0;
    CachedHomeScheduleReader.homeRefreshFor(reader)!.addListener(() => homeNotifications++);
    CachedHomeScheduleReader.scheduleRefreshFor(reader)!.addListener(() => scheduleNotifications++);
    final month = DateTime(2026, 11);
    final first = reader.readMonth(month, forDashboard: true);
    final second = reader.readMonth(month);
    await Future.wait([
      expectLater(first, throwsA(isA<CachedHomeTemporarilyUnavailable>())),
      expectLater(second, throwsA(isA<CachedHomeTemporarilyUnavailable>())),
    ]);
    gate.complete(prefs); await Future<void>.delayed(Duration.zero);
    expect(homeNotifications, 1); expect(scheduleNotifications, 1);
    expect(await reader.readMonth(month, forDashboard: true), isNull);
    expect(await reader.readMonth(month), isNull);
    expect(reads, 2);
    await Future<void>.delayed(Duration.zero);
    expect(homeNotifications, 1); expect(scheduleNotifications, 1);
    caps.dispose(); scope.dispose(); await events.close();
  });

  test('account ABA and mode changes invalidate the original reader', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final home = HomeSnapshotCache(
        project: 'test-project',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final schedule = ScheduleMonthCache(scope, 'test-project');
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final reader = CachedHomeScheduleReader(
        capabilities: capabilities, home: home, schedule: schedule);
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    await expectLater(reader.readMonth(DateTime(2026, 11)),
        throwsA(isA<CachedHomeAccessDenied>()));
    expect(
        capabilities.grant(SessionCapabilityMode.online,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    expect(
        () => CachedHomeScheduleReader(
            capabilities: capabilities, home: home, schedule: schedule),
        throwsA(isA<CachedHomeAccessDenied>()));
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('different project or same-user foreign scope is rejected', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final foreignEvents = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    final foreignScope = AuthSessionScope(
        currentSession: () => session, authEvents: foreignEvents.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    foreignEvents.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final home = HomeSnapshotCache(
        project: 'project-a',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    expect(
        () => CachedHomeScheduleReader(
            capabilities: capabilities,
            home: home,
            schedule: ScheduleMonthCache(scope, 'project-b')),
        throwsA(isA<CachedHomeAccessDenied>()));
    final foreign = CachedHomeScheduleReader(
        capabilities: capabilities,
        home: home,
        schedule: ScheduleMonthCache(foreignScope, 'project-a'));
    await expectLater(foreign.readMonth(DateTime(2026, 11)),
        throwsA(isA<CachedHomeAccessDenied>()));
    capabilities.dispose();
    scope.dispose();
    foreignScope.dispose();
    await events.close();
    await foreignEvents.close();
  });

  test('same uid cannot read home or schedule from another backend project',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('same-user-id');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    HomeSnapshotCache home(String project) => HomeSnapshotCache(
          project: project,
          authScope: scope,
          currentUserId: () => session.user.id,
          sessionGeneration: () => scope.generation,
          sessionIdentity: () => session.accessToken,
        );
    final homeA = home('backend-a');
    final homeB = home('backend-b');
    final scheduleA = ScheduleMonthCache(scope, 'backend-a');
    final scheduleB = ScheduleMonthCache(scope, 'backend-b');
    final month = DateTime(2026, 11);
    expect(
        await homeA.write(
            scope: homeA.captureScope('same-user-id')!,
            section: HomeSnapshotSection.schedule,
            items: [
              {'project': 'a'}
            ],
            savedAt: DateTime.utc(2026)),
        isTrue);
    expect(await scheduleA.write(scheduleA.begin(month)!, []), isTrue);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final readerA = CachedHomeScheduleReader(
        capabilities: capabilities, home: homeA, schedule: scheduleA);
    final readerB = CachedHomeScheduleReader(
        capabilities: capabilities, home: homeB, schedule: scheduleB);
    expect((await readerA.readHome(HomeSnapshotSection.schedule))!.items.single,
        {'project': 'a'});
    expect(await readerA.readMonth(month), isEmpty);
    expect(await readerB.readHome(HomeSnapshotSection.schedule), isNull);
    expect(await readerB.readMonth(month), isNull);
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('dashboard uses only stored sections and distinguishes unknown data',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final home = HomeSnapshotCache(
        project: 'backend',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final schedule = ScheduleMonthCache(scope, 'backend');
    final day = DateTime(2026, 11, 6);
    expect(
        await home.write(
            scope: home.captureScope('a')!,
            section: HomeSnapshotSection.profile,
            items: [
              {'id': 'a', 'name': 'Минь'}
            ],
            savedAt: DateTime.utc(2026)),
        isTrue);
    expect(await schedule.write(schedule.begin(day)!, []), isTrue);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final reader = CachedHomeScheduleReader(
        capabilities: capabilities, home: home, schedule: schedule);
    final result = await reader.readDashboard(date: day);
    expect(result.profile.name, 'Минь');
    expect(result.scheduleStatus, 'Сохранённое расписание');
    expect(result.todayLessons, isEmpty);
    expect(result.assignmentsStatus, 'Задания ещё не сохранены');
    expect(capabilities.capture(SessionCapability.networkRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('incorrect lesson date rejects day snapshot and uses valid month',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final home = HomeSnapshotCache(
        project: 'backend',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final schedule = ScheduleMonthCache(scope, 'backend');
    final day = DateTime(2026, 11, 6);
    expect(
        await home.write(
            scope: home.captureScope('a')!,
            section: HomeSnapshotSection.schedule,
            date: '2026-11-06',
            items: [
              {
                'id': 'wrong-day',
                'date': '2026-11-07',
                'week': 1,
                'day': 'СБ',
                'pair_num': 1,
                'time_start': '09:00',
                'time_end': '10:30',
                'subject': 'Не сегодняшнее занятие',
              }
            ],
            savedAt: DateTime.utc(2026)),
        isTrue);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final reader = CachedHomeScheduleReader(
        capabilities: capabilities, home: home, schedule: schedule);
    final unavailable = await reader.readDashboard(date: day);
    expect(unavailable.scheduleStatus, 'Расписание ещё не сохранено');
    expect(unavailable.todayLessons, isEmpty);
    expect(await schedule.write(schedule.begin(day)!, []), isTrue);
    final fallback = await reader.readDashboard(date: day);
    expect(fallback.scheduleStatus, 'Сохранённое расписание');
    expect(fallback.todayLessons, isEmpty);
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('UTC month boundary reads Moscow month and filters other days',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    final home = HomeSnapshotCache(
        project: 'backend',
        authScope: scope,
        currentUserId: () => session.user.id,
        sessionGeneration: () => scope.generation,
        sessionIdentity: () => session.accessToken);
    final schedule = ScheduleMonthCache(scope, 'backend');
    Lesson lesson(String id, int day) => Lesson(
        id: id,
        date: DateTime(2026, 11, day),
        week: 1,
        day: 'ПН',
        pairNum: 1,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 30),
        subjectRaw: id);
    expect(
        await schedule.write(schedule.begin(DateTime(2026, 11))!,
            [lesson('today', 1), lesson('other-day', 2)]),
        isTrue);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly,
            capabilities.beginAuthorization(scope.capture()!)!),
        isTrue);
    final reader = CachedHomeScheduleReader(
        capabilities: capabilities, home: home, schedule: schedule);
    final result =
        await reader.readDashboard(date: DateTime.utc(2026, 10, 31, 22));
    expect(result.scheduleStatus, 'Сохранённое расписание');
    expect(result.scheduleDate, DateTime(2026, 11, 1));
    expect(result.todayLessons.map((item) => item.id).toList(), ['today']);
    expect((await reader.readMonth(DateTime.utc(2026, 10, 31, 22)))!.length, 2);
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });
}
