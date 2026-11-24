import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Reader implements CachedHomeScheduleReader {
  _Reader(this.caps, {this.missing = false});
  final SessionCapabilities caps;
  final bool missing;
  @override
  Listenable get accessChanges => caps;
  @override
  bool get canRead => caps.capture(SessionCapability.cachedRead) != null;
  @override
  bool permitsContent(SessionCapabilities capabilities, CapabilityPermit permit) =>
      identical(caps, capabilities) && caps.permits(permit, SessionCapability.cachedRead);
  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
          profile: missing ? const HomeUserProfile(id: '') : const HomeUserProfile(
              id: 'a', name: 'Сохранённое имя', groupName: 'Группа'),
          scheduleDate: DateTime.now(),
          todayLessons: const [],
          assignments: const [],
          news: const []);
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
          'title': 'Сохранённый чат',
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
      'cached profile opens scoped messages without network and hides on revoke',
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
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    await tester.pumpWidget(MaterialApp(
        home: ProfileScreen(
            cachedReader: _Reader(caps),
            cachedChats: _Chats(),
            cachedCapabilities: caps)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Сохранённое имя'), findsOneWidget);
    await tester.tap(find.text('Данные приложения'));
    await tester.pumpAndSettle();
    expect(find.byType(CacheDiagnosticsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    final view = tester.widget<StudentProfileScreenPreview>(
        find.byType(StudentProfileScreenPreview));
    expect(view.onMessagesTap, isNotNull);
    view.onMessagesTap!();
    await tester.pumpAndSettle();
    expect(find.byType(MyChatsScreen), findsOneWidget);
    expect(find.text('Сохранённый чат'), findsOneWidget);
    caps.block();
    await tester.pump();
    expect(find.text('Сохранённый чат'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Сохранённый профиль недоступен.'), findsOneWidget);
    expect(find.text('Данные приложения'), findsNothing);
    // A valid cached-read permit does not require a saved profile card.
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    final reader = _Reader(caps, missing: true);
    final nav = GlobalKey<NavigatorState>();
    final home = ValueNotifier<CachedHomeScheduleReader>(reader);
    await tester.pumpWidget(MaterialApp(navigatorKey: nav,
        home: ValueListenableBuilder<CachedHomeScheduleReader>(
            valueListenable: home, builder: (_, currentReader, __) =>
                ProfileScreen(cachedReader: currentReader, cachedChats: _Chats(),
                    cachedCapabilities: caps))));
    await tester.pumpAndSettle();
    expect(find.text('Сохранённый профиль недоступен.'), findsOneWidget);
    await tester.tap(find.text('Данные приложения'));
    await tester.pumpAndSettle();
    final oldAccess = tester.widget<CacheDiagnosticsScreen>(
        find.byType(CacheDiagnosticsScreen)).canAccess!;
    expect(oldAccess(), isTrue);
    home.value = _Reader(caps, missing: true);
    await tester.pumpAndSettle();
    expect(oldAccess(), isFalse);
    expect(find.byType(CacheDiagnosticsScreen), findsNothing);
    expect(find.text('Данные недоступны.'), findsOneWidget);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    // The real diagnostics entry times out unavailable platform IO off-device.
    await tester.pump(const Duration(seconds: 6));
    home.dispose();
    caps.dispose();
    scope.dispose();
    await events.close();
    await tester.runAsync(() => Supabase.instance.dispose());
  });
}
