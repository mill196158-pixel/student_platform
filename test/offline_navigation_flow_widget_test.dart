import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Reader implements CachedHomeScheduleReader {
  _Reader(this.caps);
  final SessionCapabilities caps;
  @override
  Listenable get accessChanges => caps;
  @override
  bool get canRead => caps.capture(SessionCapability.cachedRead) != null;
  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
          profile: const HomeUserProfile(
              id: 'a', name: 'Студент офлайн', groupName: 'Группа'),
          scheduleDate: DateTime.now(),
          todayLessons: const [],
          assignments: const [],
          news: const [],
          scheduleStatus: 'Сохранённое расписание');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Chats implements ProjectChatServerCache {
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(
          SessionCapabilities caps) async =>
      [
        {
          'team': {
            'id': '',
            'name': 'Peer',
            'teacher': '',
            'groupCode': '',
            'icon': ''
          },
          'title': 'Локальный чат',
          'chatId': 'chat',
          'isDm': true,
          'peerId': 'peer',
          'unread': 0,
          'pinned': false,
          'muted': false
        }
      ];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
      'QA splash to existing home, profile and scoped chat list is network-free',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await tester.runAsync(() => Supabase.initialize(
        url: 'https://example.invalid',
        anonKey: 'test',
        httpClient: MockClient((_) async {
          calls++;
          throw StateError('unexpected network');
        }),
        authOptions: FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false)));
    final events = StreamController<AuthState>.broadcast(sync: true),
        session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope),
        reader = _Reader(caps),
        store = _Chats();
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(
          path: '/splash',
          builder: (_, __) => SplashScreen(qaAdmission: () async {
                caps.grant(SessionCapabilityMode.cacheOnly,
                    caps.beginAuthorization(scope.capture()!)!);
                return OfflineStartupResult.cacheOnly;
              })),
      GoRoute(
          path: '/home',
          builder: (_, __) => NavigationScreen(
              cachedReader: reader,
              cachedProfile: (_) => ProfileScreen(
                  cachedReader: reader,
                  cachedChats: store,
                  cachedCapabilities: caps))),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.textContaining('Студент офлайн'), findsOneWidget);
    await tester.tap(find.text('Профиль').last);
    await tester.pumpAndSettle();
    final profile = tester.widget<StudentProfileScreenPreview>(
        find.byType(StudentProfileScreenPreview));
    profile.onMessagesTap!();
    await tester.pumpAndSettle();
    expect(find.byType(MyChatsScreen), findsOneWidget);
    expect(find.text('Локальный чат'), findsOneWidget);
    expect(calls, 0);
    caps.block();
    await tester.pump();
    expect(find.text('Локальный чат'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    caps.dispose();
    scope.dispose();
    await events.close();
    await tester.runAsync(() => Supabase.instance.dispose());
  });
}
