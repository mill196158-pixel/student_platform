import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'home_progressive_loading_test.dart' show signIn;

class _Schedule implements ScheduleRepository {
  @override Future<List<Lesson>> loadRange(DateTime from, {required int days, bool strict = false}) async => [];
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
class _Learning implements SupabaseLearningRepository {
  @override Future<List<Team>> loadTeams(String group, {bool strict = false}) async => [];
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final offline in [true, false]) {
    test('home retains prior group action only for transport failure=$offline', () async {
      SharedPreferences.setMockInitialValues({});
      final client = SupabaseClient('https://example.invalid', 'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/rpc/list_my_group_action_deadlines')) {
              if (offline) throw const SocketException('offline');
              return http.Response('{"message":"denied","code":"42501"}', 403,
                  request: request, headers: {'content-type': 'application/json'});
            }
            return http.Response('[]', 200, request: request,
                headers: {'content-type': 'application/json'});
          }));
      await signIn(client, 'owner');
      final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
      await scope.ready;
      final service = HomeDashboardService(client: client, sessionScope: scope,
          scheduleRepository: _Schedule(), learningRepository: _Learning());
      final previous = HomeDashboardData(profile: const HomeUserProfile(id: 'owner'),
          scheduleDate: MskDate.today(), todayLessons: const [], assignments: const [], news: const [],
          groupActions: [HomeGroupActionPreview(eventType: 'collection_deadline',
              entityId: 'old', title: 'Сохранённый сбор', occursAt: DateTime(2026, 11, 5))]);
      final result = await service.load(previous: previous);
      expect(result.groupActions.length, offline ? 1 : 0);
      service.dispose(); scope.dispose(); await client.dispose();
    });
  }
}
