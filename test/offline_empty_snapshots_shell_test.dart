import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/local_snapshot_startup.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty snapshots keep the ordinary shell offline, then revoke it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    await tester.runAsync(() => Supabase.initialize(
      url: 'https://example.invalid', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((_) async { requests++; throw StateError('network'); }),
    ));
    final events = StreamController<AuthState>.broadcast(sync: true);
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final session = Session(accessToken: '${part({'alg': 'HS256'})}.${part({
      'iss': 'https://example.invalid/auth/v1', 'sub': 'empty-owner',
      'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'aud': 'authenticated', 'role': 'authenticated', 'iat': now - 60, 'exp': now + 3600,
    })}.sig', refreshToken: 'fixture', tokenType: 'bearer',
      user: User(id: 'empty-owner', appMetadata: const {}, userMetadata: null,
        aud: 'authenticated', createdAt: ''));
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final startup = LocalSnapshotStartup(scope: scope,
      issuer: 'https://example.invalid/auth/v1',
      restore: () async => SessionRestoreStatus.transportFailure,
      checkPolicy: () async => throw StateError('unexpected policy request'));
    expect(await startup.resolve(caps), OfflineStartupResult.cacheOnly);
    final home = HomeSnapshotCache(project: 'empty-project', authScope: scope,
      currentUserId: () => session.user.id, sessionGeneration: () => scope.generation,
      sessionIdentity: () => session.accessToken);
    final reader = CachedHomeScheduleReader(capabilities: caps, home: home,
      schedule: ScheduleMonthCache(scope, 'empty-project'));
    await tester.pumpWidget(MaterialApp(home: NavigationScreen(cachedReader: reader)));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationScreen), findsOneWidget);
    expect(find.text('Главная'), findsWidgets);
    expect(find.text('Расписание ещё не сохранено'), findsWidgets);
    expect(find.text('Сегодня выходной'), findsNothing);
    for (final tab in ['База', 'Обучение', 'Расписание', 'Профиль']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationScreen), findsOneWidget);
    }
    expect(requests, 0);
    expect(caps.capture(SessionCapability.mutation), isNull);
    caps.block();
    await tester.pump();
    expect(find.text('Сохранённые данные недоступны.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
    await tester.runAsync(() => Supabase.instance.dispose());
  });
}
