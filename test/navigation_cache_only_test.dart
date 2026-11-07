import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _LocalReader extends ChangeNotifier implements CachedHomeScheduleReader {
  bool allowed = true;
  @override
  Listenable get accessChanges => this;
  @override
  bool get canRead => allowed;

  void revoke() {
    allowed = false;
    notifyListeners();
  }

  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
        profile: const HomeUserProfile(
            id: 'fixture', name: 'Локальный пользователь'),
        scheduleDate: DateTime(2026, 11, 6),
        todayLessons: const [],
        assignments: const [],
        news: const [],
        scheduleStatus: 'Сохранённое расписание',
        assignmentsStatus: 'Сохранённые задания',
      );

  @override
  Future<List<Lesson>?> readMonth(DateTime month, {bool forDashboard = false}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var requests = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.invalid',
      publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((_) async {
        requests++;
        throw StateError('unexpected network');
      }),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets('cache-only navigation uses local home and local tab builders',
      (tester) async {
    final reader = _LocalReader();
    await tester.pumpWidget(MaterialApp(
        home: NavigationScreen(
      cachedReader: reader,
      cachedLearning: (_) => const Text('Локальные чаты'),
    )));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Локальный пользователь'), findsOneWidget);
    await tester.tap(find.text('Обучение'));
    await tester.pump();
    expect(find.text('Локальные чаты'), findsOneWidget);
    await tester.tap(find.text('База'));
    await tester.pump();
    expect(find.text('Сохранённые данные этого раздела пока недоступны.'),
        findsOneWidget);
    reader.revoke();
    await tester.pump();
    expect(find.text('Сохранённые данные недоступны.'), findsOneWidget);
    expect(find.text('Локальные чаты'), findsNothing);
    expect(find.textContaining('Локальный пользователь'), findsNothing);
    expect(requests, 0);
  });
}
