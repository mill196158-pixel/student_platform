import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';

class Schedule implements ScheduleRepository {
  final result = Completer<List<Lesson>>();
  @override
  Future<List<Lesson>> loadRange(DateTime from,
          {required int days, bool strict = false}) =>
      result.future;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Learning implements SupabaseLearningRepository {
  final gates = List.generate(8, (_) => Completer<List<Assignment>>());
  int started = 0;
  @override
  Future<List<Team>> loadTeams(String group, {bool strict = false}) async =>
      List.generate(
          8,
          (i) => Team(
              id: '$i',
              name: 'Team $i',
              teacher: '',
              groupCode: 'g',
              icon: ''));
  @override
  Future<List<Assignment>> loadAssignments(String id, {bool strict = false}) {
    started++;
    return gates[int.parse(id)].future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> signIn(SupabaseClient client, String id) async {
  String b(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  await client.auth.recoverSession(jsonEncode({
    'access_token':
        '${b({'alg': 'HS256'})}.${b({'sub': id, 'exp': expiry})}.sig',
    'token_type': 'bearer',
    'refresh_token': 'test',
    'expires_at': expiry,
    'expires_in': 3600,
    'user': {
      'id': id,
      'app_metadata': {},
      'user_metadata': {},
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z'
    }
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'cached first paint, independent sections, four parallel assignment requests, account isolation',
      () async {
    SharedPreferences.setMockInitialValues({
      'user': jsonEncode({'id': 'a', 'name': 'Cached A', 'group_name': 'g'})
    });
    final profile = Completer<http.Response>();
    final news = Completer<http.Response>();
    final requested = <String>[];
    final client = SupabaseClient('https://example.test', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) async {
      requested.add(r.url.path);
      if (r.url.path.endsWith('get_my_profile')) {
        final v = await profile.future;
        return http.Response(v.body, v.statusCode, request: r);
      }
      if (r.url.path.endsWith('get_my_published_news')) {
        final v = await news.future;
        return http.Response(v.body, v.statusCode, request: r);
      }
      return http.Response('[]', 200,
          request: r, headers: {'content-type': 'application/json'});
    }));
    addTearDown(client.dispose);
    await signIn(client, 'a');
    final schedule = Schedule();
    final learning = Learning();
    final updates = <HomeDashboardData>[];
    final service = HomeDashboardService(
        client: client,
        scheduleRepository: schedule,
        learningRepository: learning);
    final watch = Stopwatch()..start();
    final work = service.load(onUpdate: updates.add);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(updates.any((d) => d.profile.name == 'Cached A'), isTrue);
    expect(profile.isCompleted, isFalse);
    expect(learning.started, 4);
    expect(news.isCompleted, isFalse);
    expect(requested.any((p) => p.endsWith('get_my_published_news')), isTrue);
    expect(updates.last.scheduleStatus, isNotNull);
    print(
        'Cached dashboard published within ${watch.elapsedMilliseconds} ms while profile/news held');
    schedule.result.complete([]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(updates.last.scheduleStatus, isNull);
    profile.complete(http.Response(
        '[{"id":"a","name":"Fresh A","group_name":"g"}]', 200,
        headers: {'content-type': 'application/json'}));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(learning.started, 4);
    expect(updates.last.profile.name, 'Fresh A');
    for (final gate in learning.gates.take(4)) {
      gate.complete([]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(learning.started, 8);
    final count = updates.length;
    await signIn(client, 'b');
    for (final gate in learning.gates.skip(4)) {
      gate.complete([]);
    }
    news.complete(http.Response('[]', 200,
        headers: {'content-type': 'application/json'}));
    await expectLater(work, throwsStateError);
    expect(updates.length, count);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getKeys().any((k) =>
            k.startsWith(PublishedNewsCache.keyPrefix) && k.endsWith('__b')),
        isFalse);
  });
  test('failed schedule is not presented as an empty day', () async {
    SharedPreferences.setMockInitialValues({});
    final client = SupabaseClient('https://example.test', 'test',
        httpClient: MockClient((r) async => http.Response('[]', 200,
            request: r, headers: {'content-type': 'application/json'})),
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    addTearDown(client.dispose);
    final schedule = Schedule();
    final learning = Learning();
    final work = HomeDashboardService(
            client: client,
            scheduleRepository: schedule,
            learningRepository: learning)
        .load();
    schedule.result.completeError(StateError('offline'));
    for (final gate in learning.gates) {
      gate.complete([]);
    }
    final data = await work;
    expect(data.scheduleStatus, 'Не удалось обновить расписание');
  });
}
