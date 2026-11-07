import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/info_subjects_cache.dart';
import 'package:student_platform/src/ui/info/offline_subject_catalog.dart';
import 'package:student_platform/src/ui/info/useful_subjects_repository.dart';
import 'package:student_platform/src/ui/info/reference_service.dart';
import 'package:student_platform/src/ui/info/vacancy_service.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _EmptyVacancies implements VacancyRpcClient {
  @override Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async => [];
}
class _EmptyReference implements ReferenceRpcClient {
  @override Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async => [];
}

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences(Map<String, Object> values) : super.withData(values);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Map<String, Object>> getAll() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.getAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('a local plan read finishing after barrier close cannot paint or refresh', (tester) async {
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
    final key = InfoSubjectsCache.prefsKey('cache-user');
    final delayed = _DelayedPreferences({'flutter.$key': jsonEncode({
      'contextData': {'userId': 'cache-user', 'groupId': 'group', 'groupName': 'Cached group',
        'currentSemesterNumber': 4, 'hasActiveEnrollment': true},
      'subjects': [{'id': 'cached', 'title': 'Old cached subject', 'groupId': 'group',
        'semesterNumber': 4, 'controlForm': 'Экзамен'}],
      'warning': null,
    })});
    SharedPreferencesStorePlatform.instance = delayed;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    var refreshes = 0;
    await tester.pumpWidget(MaterialApp(home: InfoScreen(
      debugUserId: 'cache-user', onlineBarrier: barrier,
      planLoader: () async { refreshes++; throw StateError('unexpected refresh'); },
      vacancyService: VacancyService(rpcClient: _EmptyVacancies(), currentUserId: () => 'cache-user'),
      referenceService: ReferenceService(rpcClient: _EmptyReference(), currentUserId: () => 'cache-user'),
    )));
    await tester.pump();
    expect(delayed.entered.isCompleted, isTrue);
    barrier.close();
    delayed.release.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Old cached subject'), findsNothing);
    expect(refreshes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
  });
  test('a failed in-flight subject request never starts a fallback after invalidation', () async {
    final response = Completer<List<Map<String, dynamic>>>();
    var current = true;
    var fallbacks = 0;
    final repository = UsefulSubjectsRepository(rpcLoader: () => response.future,
        fallbackLoader: (_) async { fallbacks++; return []; });
    final pending = repository.load(groupId: 'group', isCurrent: () => current);
    current = false;
    response.completeError(StateError('offline'));
    await expectLater(pending, throwsStateError);
    expect(fallbacks, 0);
  });
  testWidgets('ordinary Base shows only the current session saved subject plan', (tester) async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('subject-catalog-')))!;
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
    ProjectChatServerCache cache() => ProjectChatServerCache(db: db!, scope: scope, currentBinding: binding, project: project);
    var chat = cache();
    var store = OfflineSubjectCatalog(chat);
    final plan = <String, dynamic>{
      'contextData': {'userId': 'a', 'groupId': 'group', 'groupName': 'Тестовая группа',
        'currentSemesterNumber': 4, 'hasActiveEnrollment': true},
      'subjects': [
        {'id': 'exam', 'title': 'Тестовый экзамен', 'groupId': 'group', 'semesterNumber': 4,
          'controlForm': 'Экзамен', 'description': 'Описание предмета', 'teacherName': 'Преподаватель'},
        {'id': 'practice', 'title': 'Учебная практика', 'groupId': 'group', 'semesterNumber': 4,
          'controlForm': 'Практика', 'description': '', 'teacherName': ''},
      ],
      'warning': null,
    };
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
    var onlineLoads = 0;
    final liveRepo = UsefulSubjectsRepository(rpcLoader: () async {
      onlineLoads++;
      return [{'subject_offering_id': 'exam', 'subject_title': 'Тестовый экзамен',
        'group_id': 'group', 'semester_number': 4, 'control_form': 'Экзамен'}];
    });
    await tester.pumpWidget(MaterialApp(home: InfoScreen(
      debugUserId: 'a', debugOnlineStore: chat, subjectsRepository: liveRepo,
      debugStrictContextLoader: () async => const AcademicContext(userId: 'a', groupId: 'group',
        groupName: 'Тестовая группа', currentSemesterNumber: 4, hasActiveEnrollment: true),
      vacancyService: VacancyService(rpcClient: _EmptyVacancies(), currentUserId: () => 'a'),
      referenceService: ReferenceService(rpcClient: _EmptyReference(), currentUserId: () => 'a'),
    )));
    Map<String, dynamic>? onlineSnapshot;
    for (var i = 0; i < 60 && onlineSnapshot == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      onlineSnapshot = await tester.runAsync<Map<String, dynamic>?>(() => store.read(caps));
    }
    expect(onlineLoads, 1);
    expect((onlineSnapshot!['subjects'] as List).single['title'], 'Тестовый экзамен');
    await tester.pumpWidget(const SizedBox.shrink());
    final lateContext = Completer<AcademicContext>();
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    var lateRequests = 0;
    final lateRepo = UsefulSubjectsRepository(rpcLoader: () async { lateRequests++; return []; });
    await tester.pumpWidget(MaterialApp(home: InfoScreen(debugUserId: 'a',
      debugOnlineStore: chat, debugStrictContextLoader: () => lateContext.future,
      onlineBarrier: barrier,
      subjectsRepository: lateRepo,
      vacancyService: VacancyService(rpcClient: _EmptyVacancies(), currentUserId: () => 'a'),
      referenceService: ReferenceService(rpcClient: _EmptyReference(), currentUserId: () => 'a'))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(barrier.activeCount, greaterThan(0));
    expect(await tester.runAsync(() => barrier.closeAndDrain(timeout: const Duration(milliseconds: 20))), isFalse);
    await tester.pumpWidget(MaterialApp(home: InfoScreen(cachedStore: chat,
        cachedCapabilities: caps, subjectsRepository: lateRepo)));
    lateContext.complete(const AcademicContext(userId: 'a', groupId: 'group',
        groupName: 'Тестовая группа', currentSemesterNumber: 4, hasActiveEnrollment: true));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(lateRequests, 0);
    expect(barrier.activeCount, 0);
    expect((await tester.runAsync(() => store.read(caps)))!['subjects'], isNotEmpty);
    expect(find.text('Тестовый экзамен'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    final stale = await tester.runAsync(() => store.begin(isCurrent: () => true));
    final current = await tester.runAsync(() => store.begin(isCurrent: () => true));
    expect(await tester.runAsync(() => store.commit(current!, plan)), isTrue);
    expect(await tester.runAsync(() => store.commit(stale!, plan)), isFalse);
    final denied = await tester.runAsync(() => store.begin(isCurrent: () => true));
    final pending = await tester.runAsync(() => store.begin(isCurrent: () => true));
    await tester.runAsync(() => store.deny(denied!));
    expect(await tester.runAsync(() => store.read(caps)), isNull);
    expect(await tester.runAsync(() => store.commit(pending!, plan)), isFalse);
    final restored = await tester.runAsync(() => store.begin(isCurrent: () => true));
    expect(await tester.runAsync(() => store.commit(restored!, plan)), isTrue);
    await tester.runAsync(() => closeProjectChatServerDatabase(db!));
    db = await tester.runAsync(() => openProjectChatServerDatabase(path, factory: databaseFactoryFfi));
    chat = cache(); store = OfflineSubjectCatalog(chat);
    final recovered = await tester.runAsync(() => store.read(caps));
    expect((recovered!['subjects'] as List).map((e) => e['title']).toList(),
        ['Тестовый экзамен', 'Учебная практика']);
    var networkCalls = 0;
    final repo = UsefulSubjectsRepository(rpcLoader: () async { networkCalls++; throw StateError('unexpected network'); },
      fallbackLoader: (_) async { networkCalls++; throw StateError('unexpected network'); });
    await tester.pumpWidget(MaterialApp(home: InfoScreen(cachedStore: chat,
      cachedCapabilities: caps, subjectsRepository: repo)));
    for (var i = 0; i < 60 && find.text('Тестовый экзамен').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Тестовая группа'), findsOneWidget);
    expect(find.text('Тестовый экзамен'), findsOneWidget);
    expect(find.text('Экзамены'), findsOneWidget);
    expect(find.text('Практики'), findsOneWidget);
    expect(find.text('Предметы учебного плана пока не найдены'), findsNothing);
    expect(networkCalls, 0);
    await tester.tap(find.text('Тестовый экзамен'));
    await tester.pumpAndSettle();
    expect(find.text('Описание предмета'), findsOneWidget);
    caps.block(); await tester.pump();
    expect(find.text('Описание предмета'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    session = sessionFor('a', sidA, nonce: 1);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session)); allow();
    expect(await tester.runAsync(() => store.read(caps)), isNotNull);
    session = sessionFor('b', sidB);
    events.add(AuthState(AuthChangeEvent.signedIn, session)); allow();
    expect(await tester.runAsync(() => store.read(caps)), isNull);
    session = sessionFor('a', sidB);
    events.add(AuthState(AuthChangeEvent.signedIn, session)); allow();
    expect(await tester.runAsync(() => store.read(caps)), isNull);
    await tester.pumpWidget(MaterialApp(home: InfoScreen(cachedStore: chat,
      cachedCapabilities: caps, subjectsRepository: repo)));
    for (var i = 0; i < 60 && find.textContaining('Предметы ещё не сохранены').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('Предметы ещё не сохранены'), findsOneWidget);
    expect(find.text('Предметы учебного плана пока не найдены'), findsNothing);
    expect(networkCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose(); scope.dispose(); await events.close();
    await tester.runAsync(() => closeProjectChatServerDatabase(db!));
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
