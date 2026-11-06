import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
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
}
