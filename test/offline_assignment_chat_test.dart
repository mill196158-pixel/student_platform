import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/offline_assignment_store.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('saved assignment, text and service message survive cold offline in order', (tester) async {
    await initializeDateFormatting('ru');
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('offline-assignment-')))!;
    const project = 'https://example.invalid';
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    Session sessionFor(String uid, String sid, {int nonce = 0}) {
      final part = base64Url.encode(utf8.encode(jsonEncode({
        'iss': '$project/auth/v1', 'sub': uid, 'session_id': sid,
        'aud': 'authenticated', 'role': 'authenticated', 'iat': now - 10 + nonce, 'exp': now + 3600 + nonce,
      }))).replaceAll('=', '');
      return fakeSession(uid, access: 'header.$part.signature');
    }
    const sidA = '11111111-1111-1111-1111-111111111111';
    const sidB = '22222222-2222-2222-2222-222222222222';
    var session = sessionFor('a', sidA);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    void allow() => expect(caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!), isTrue);
    allow();
    OfflineSessionBinding? binding() => OfflineSessionBinding.fromSession(session, '$project/auth/v1');
    final path = '${dir.path}/chat.db';
    var db = await tester.runAsync(() => openProjectChatServerDatabase(path, factory: databaseFactoryFfi));
    expect(db, isNotNull);
    ProjectChatServerCache cache() => ProjectChatServerCache(db: db!, scope: scope,
        currentBinding: binding, project: project);
    var chat = cache();
    var store = OfflineAssignmentStore(chat);
    final at = DateTime.utc(2026, 6, 20, 10);
    final assignment = Assignment(id: 'task', title: 'Скинуться на билеты',
        description: 'купить билеты', due: '21.06', published: true,
        votes: 0, completedByMe: false, createdBy: 'student', createdAt: at);
    final first = await tester.runAsync(() => store.begin('team', isCurrent: () => true));
    expect(first, isNotNull);
    final newer = await tester.runAsync(() => store.begin('team', isCurrent: () => true));
    expect(await tester.runAsync(() => store.commit(newer!, [assignment])), isTrue);
    expect(await tester.runAsync(() => store.commit(first!, [assignment])), isFalse);
    final ticket = await tester.runAsync(() => chat.begin('chat'));
    final messages = [
      Message(id: 'card', chatId: 'chat', authorId: 'a', authorLogin: 'a',
          authorName: 'Автор', text: '', at: at, assignmentId: 'task',
          type: MessageType.assignmentPublished),
      Message(id: 'text', chatId: 'chat', authorId: 'a', authorLogin: 'a',
          authorName: 'Автор', text: 'Привет', at: at.add(const Duration(minutes: 1))),
      Message(id: 'service', chatId: 'chat', authorId: 'a', authorLogin: 'a',
          authorName: 'Автор', text: 'Новое задание: Скинуться на билеты',
          at: at.add(const Duration(minutes: 2))),
    ];
    expect(await tester.runAsync(() => chat.saveServerPage(ticket!, messages, hasMore: false)), isTrue);
    await tester.runAsync(() => closeProjectChatServerDatabase(db!));
    db = await tester.runAsync(() => openProjectChatServerDatabase(path, factory: databaseFactoryFfi));
    chat = cache();
    store = OfflineAssignmentStore(chat);
    expect((await tester.runAsync(() => store.read('team', caps)))?.single.title,
        'Скинуться на билеты');
    final deniedAttempt = await tester.runAsync(() => store.begin('team', isCurrent: () => true));
    final newerAttempt = await tester.runAsync(() => store.begin('team', isCurrent: () => true));
    await tester.runAsync(() => store.deny(deniedAttempt!));
    expect(await tester.runAsync(() => store.read('team', caps)), isNull);
    expect(await tester.runAsync(() => store.commit(newerAttempt!, [assignment])), isFalse);
    final allowedAgain = await tester.runAsync(() => store.begin('team', isCurrent: () => true));
    expect(await tester.runAsync(() => store.commit(allowedAgain!, [assignment])), isTrue);

    await tester.pumpWidget(MaterialApp(home: TeamDetailsScreen(
      team: const Team(id: 'team', name: 'Предмет', teacher: '', groupCode: '', icon: ''),
      cachedStore: chat, cachedCapabilities: caps, cachedChatId: 'chat')));
    for (var i = 0; i < 50 && find.text('Скинуться на билеты').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Скинуться на билеты'), findsOneWidget);
    expect(find.text('купить билеты'), findsOneWidget);
    expect(find.text('Привет'), findsOneWidget);
    expect(find.text('Новое задание: Скинуться на билеты'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Скинуться на билеты')).dy,
        lessThan(tester.getTopLeft(find.text('Привет')).dy));
    expect(tester.getTopLeft(find.text('Привет')).dy,
        lessThan(tester.getTopLeft(find.text('Новое задание: Скинуться на билеты')).dy));
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Опубликовано · сохранённая копия'), findsOneWidget);
    expect(find.text('купить билеты'), findsOneWidget);
    caps.block();
    await tester.pump();
    expect(find.text('купить билеты'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    // A refresh of the same server session can read the persisted snapshot.
    session = sessionFor('a', sidA, nonce: 1);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    allow();
    expect((await tester.runAsync(() => store.read('team', caps)))?.single.title,
        'Скинуться на билеты');
    // A different account or SID cannot read the saved assignment.
    session = sessionFor('b', sidB);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    allow();
    expect(await tester.runAsync(() => store.read('team', caps)), isNull);
    session = sessionFor('a', sidB);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    allow();
    expect(await tester.runAsync(() => store.read('team', caps)), isNull);
    caps.dispose(); scope.dispose(); await events.close();
    await tester.runAsync(() => closeProjectChatServerDatabase(db!));
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
