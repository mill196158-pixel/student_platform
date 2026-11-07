import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_progressive_loading_test.dart' show signIn;

class _Schedule implements ScheduleRepository {
  int calls = 0;
  @override
  Future<List<Lesson>> loadMonthForPrewarm(DateTime month,
      {required bool Function() isCurrent}) async {
    expect(isCurrent(), isTrue);
    calls++;
    return [];
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Learning implements SupabaseLearningRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordinary service saves a month without QA flags', () async {
    expect(const bool.fromEnvironment('SQLITE_POLICY_QA'), isFalse);
    SharedPreferences.setMockInitialValues({});
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response('[]', 200,
            request: request, headers: {'content-type': 'application/json'})));
    await signIn(client, 'prewarm-owner');
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    final owner = scope.capture()!;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => scope.isCurrent(owner));
    final schedule = _Schedule();
    final dashboard = HomeDashboardService(client: client, sessionScope: scope,
        scheduleRepository: schedule, learningRepository: _Learning());
    await dashboard.prewarmSchedule(barrier);
    expect(schedule.calls, greaterThan(0));
    final cache = ScheduleMonthCache(scope, SupabaseConfig.url);
    expect(await cache.read(cache.beginRead(MskDate.today())!), isEmpty);
    barrier.close();
    final oldCalls = schedule.calls;
    await dashboard.prewarmSchedule(barrier);
    expect(schedule.calls, oldCalls);
    dashboard.dispose();
    scope.dispose();
    await client.dispose();
  });
}
