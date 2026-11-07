import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/scoped_team_catalog.dart';
import 'package:student_platform/src/ui/navigation/cached_team_chat_directory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Cache implements ProjectChatServerCache {
  _Cache(this.db, this.scope, this.currentBinding);
  @override
  final Database db;
  @override
  final AuthSessionScope scope;
  @override
  final OfflineSessionBinding? Function() currentBinding;
  @override
  String get project => 'https://example.invalid';
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(
          SessionCapabilities caps) async =>
      [
        {
          'isDm': false,
          'chatId': 'chat-s',
          'team': {
            'id': 's',
            'name': 'Subject',
            'teacher': 'Teacher',
            'groupCode': 'G',
            'icon': '',
            'kind': 'subject'
          }
        }
      ];
  @override
  Future<List<Message>?> read(String chat, SessionCapabilities caps) async =>
      null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Session _session(String uid, String sid) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String part(Object x) =>
      base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
  return Session(
      accessToken: '${part({'alg': 'HS256'})}.${part({
            'iss': 'https://example.invalid/auth/v1',
            'sub': uid,
            'session_id': sid,
            'role': 'authenticated',
            'aud': 'authenticated',
            'iat': now - 60,
            'exp': now + 3600
          })}.sig',
      refreshToken: 'local',
      tokenType: 'bearer',
      user: User(
          id: uid,
          appMetadata: const {},
          userMetadata: null,
          aud: 'authenticated',
          createdAt: ''));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  testWidgets(
      'offline catalog shows teams without any saved chats and fences account change',
      (tester) async {
    final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('team-catalog-widget-')))!;
    final db = (await tester.runAsync(
        () => databaseFactoryFfi.openDatabase('${root.path}/cache.db')))!;
    var session = _session('a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    OfflineSessionBinding? binding() => OfflineSessionBinding.fromSession(
        session, 'https://example.invalid/auth/v1');
    final catalog = ScopedTeamCatalogStore(
        db: db,
        scope: scope,
        currentBinding: binding,
        project: 'https://example.invalid');
    expect(
        caps.grant(SessionCapabilityMode.online,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    final ticket = (await tester.runAsync(() => catalog.begin(caps)))!;
    expect(
        await tester.runAsync(() => catalog.commit(
            ticket,
            caps,
            [
              const Team(
                  id: 's',
                  name: 'Subject',
                  teacher: 'Teacher',
                  groupCode: 'G',
                  icon: '',
                  kind: 'subject'),
              const Team(
                  id: 'u',
                  name: 'Unknown',
                  teacher: '',
                  groupCode: '',
                  icon: '',
                  kind: 'unknown'),
              const Team(
                  id: 'g',
                  name: 'Group',
                  teacher: '',
                  groupCode: 'G',
                  icon: '',
                  kind: 'group_space'),
            ],
            DateTime.utc(2026, 1, 2))),
        isTrue);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    await tester.pumpWidget(MaterialApp(
        home: CachedTeamChatDirectory(
            store: _Cache(db, scope, binding),
            capabilities: caps,
            subjectsOnly: false)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Subject'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('Group'), findsOneWidget);
    expect(find.text('Тип команды не подтверждён'), findsOneWidget);
    expect(find.text('История не сохранена на устройстве'), findsNWidgets(3));
    expect(find.textContaining('Данные могут устареть'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Group')).dy,
        lessThan(tester.getTopLeft(find.text('Subject')).dy));
    expect(await tester.runAsync(() => catalog.deny(ticket)), isTrue);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Subject'), findsNothing,
        reason: 'denied catalog cannot fall back to old chat summaries');
    expect(caps.capture(SessionCapability.cachedRead), isNotNull,
        reason: 'a local catalog denial does not block other offline sections');
    session = _session('b', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(find.text('Subject'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
  });
}
