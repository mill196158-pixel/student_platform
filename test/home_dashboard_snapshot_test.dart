import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_progressive_loading_test.dart' show signIn;

class _Schedule implements ScheduleRepository {
  final result = Completer<List<Lesson>>();
  @override
  Future<List<Lesson>> loadRange(DateTime from,
          {required int days, bool strict = false}) =>
      result.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Learning implements SupabaseLearningRepository {
  final teams = Completer<List<Team>>();
  @override
  Future<List<Team>> loadTeams(String group, {bool strict = false}) =>
      teams.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ScheduleQueue implements ScheduleRepository {
  final requests = <Completer<List<Lesson>>>[];
  @override
  Future<List<Lesson>> loadRange(DateTime from,
      {required int days, bool strict = false}) {
    final result = Completer<List<Lesson>>();
    requests.add(result);
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyLearning implements SupabaseLearningRepository {
  @override
  Future<List<Team>> loadTeams(String group, {bool strict = false}) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('existing dashboard publishes cached sections before stalled requests',
      () async {
    SharedPreferences.setMockInitialValues({});
    final networkGate = Completer<void>();
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      await networkGate.future;
      if (request.url.path.endsWith('/get_my_profile')) {
        return http.Response('{"message":"unavailable"}', 403,
            request: request, headers: {'content-type': 'application/json'});
      }
      return http.Response('[]', 200,
          request: request, headers: {'content-type': 'application/json'});
    }));
    await signIn(client, 'a');
    final source = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await source.ready;
    final cache = HomeSnapshotCache(
        currentUserId: () => source.capture()?.userId,
        sessionGeneration: () => source.generation,
        sessionIdentity: source.capture);
    final scope = cache.captureScope('a')!;
    final today = MskDate.today();
    final lesson = Lesson(
        id: 'l',
        date: today,
        week: 1,
        day: 'ЧТ',
        pairNum: 1,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 0),
        subjectRaw: 'Водоснабжение (л.)');
    final assignment = Assignment(
        id: 't',
        title: 'Задание',
        description: '',
        published: true,
        votes: 0,
        completedByMe: false,
        createdBy: 'student',
        createdAt: DateTime.utc(2026));
    await cache.write(
        scope: scope,
        section: HomeSnapshotSection.schedule,
        date: MskDate.isoDate(today),
        items: [HomeSnapshotCodec.lessonToMap(lesson)],
        savedAt: DateTime.now());
    await cache.write(
        scope: scope,
        section: HomeSnapshotSection.profile,
        items: [
          {'id': 'a', 'name': 'Cached Student'}
        ],
        savedAt: DateTime.now());
    await cache.write(
        scope: scope,
        section: HomeSnapshotSection.assignments,
        items: [
          HomeSnapshotCodec.assignmentToMap(HomeAssignmentPreview(
              assignment: assignment, teamName: 'Команда'))
        ],
        savedAt: DateTime.now());
    final schedule = _Schedule();
    final learning = _Learning();
    final updates = <HomeDashboardData>[];
    final service = HomeDashboardService(
        client: client,
        scheduleRepository: schedule,
        learningRepository: learning,
        sessionScope: source,
        snapshotCache: cache);
    final work = service.load(onUpdate: updates.add);
    for (var i = 0; i < 30 && updates.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(updates, isNotEmpty);
    expect(updates.first.todayLessons.single.id, 'l');
    expect(updates.first.assignments.single.assignment.id, 't');
    expect(updates.first.profile.name, 'Cached Student');
    networkGate.complete();
    schedule.result.completeError(StateError('offline'));
    learning.teams.completeError(StateError('offline'));
    final result = await work;
    expect(result.todayLessons.single.id, 'l');
    expect(result.assignments.single.assignment.id, 't');
    expect(result.profile.name, 'Cached Student');
    service.dispose();
    final lateSchedule = _Schedule();
    final lateLearning = _Learning();
    final retryService = HomeDashboardService(
      client: client,
      scheduleRepository: lateSchedule,
      learningRepository: lateLearning,
      sessionScope: source,
      snapshotCache: cache,
    );
    final lateUpdates = <HomeDashboardData>[];
    final lateWork = retryService.load(onUpdate: lateUpdates.add);
    for (var i = 0; i < 30 && lateUpdates.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(lateUpdates, isNotEmpty);
    lateUpdates.clear();
    source.invalidateForSignOut();
    lateSchedule.result.complete([]);
    lateLearning.teams.complete([]);
    await expectLater(lateWork, throwsA(isA<HomeLoadCancelled>()));
    expect(lateUpdates, isEmpty);
    retryService.dispose();
    source.dispose();
    await client.dispose();
  });

  test('older request cannot overwrite the newer successful schedule',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response('[]', 200,
            request: request, headers: {'content-type': 'application/json'})));
    await signIn(client, 'a');
    final source = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await source.ready;
    final cache = HomeSnapshotCache(
        currentUserId: () => source.capture()?.userId,
        sessionGeneration: () => source.generation,
        sessionIdentity: source.capture);
    final schedules = _ScheduleQueue();
    final service = HomeDashboardService(
        client: client,
        scheduleRepository: schedules,
        learningRepository: _EmptyLearning(),
        sessionScope: source,
        snapshotCache: cache);
    final first = service.load();
    final oldExpected = expectLater(first, throwsA(isA<HomeLoadCancelled>()));
    while (schedules.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = service.load();
    while (schedules.requests.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    Lesson lesson(String id) => Lesson(
        id: id,
        date: MskDate.today(),
        week: 1,
        day: 'ЧТ',
        pairNum: 1,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 0),
        subjectRaw: id);
    schedules.requests[1].complete([lesson('new')]);
    expect((await second).todayLessons.single.id, 'new');
    schedules.requests[0].complete([lesson('old')]);
    await oldExpected;
    await Future<void>.delayed(Duration.zero);
    final saved = await cache.read('a', HomeSnapshotSection.schedule);
    expect(saved!.items.single['id'], 'new');
    service.dispose();
    source.dispose();
    await client.dispose();
  });
}
