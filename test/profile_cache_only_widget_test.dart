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
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
    await tester.runAsync(() => Supabase.instance.dispose());
  });
}
