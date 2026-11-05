import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cache_owner.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/state/verified_empty_team_chat.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

class _Repository implements LearningRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<AuthState> events;
  late Session current;
  late AuthSessionScope scope;
  late TeamCacheOwner owner;
  const team = Team(
      id: 'team', name: 'Учебный чат', teacher: '', groupCode: '', icon: '');
  Map<String, String> mapping() =>
      {'id': 'chat', 'team_id': 'team', 'type': 'team_main'};

  setUp(() async {
    await TeamCubit.clearSessionCaches();
    await ChatMessageCacheStore.clearAllMemory();
    SharedPreferences.setMockInitialValues({});
    ChatMessageCacheStore.debugSetPrefs(await SharedPreferences.getInstance());
    current = fakeSession('a');
    events = StreamController<AuthState>.broadcast(sync: true);
    scope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    owner = TeamCacheOwner.bind(scope, team.id)!;
  });
  tearDown(() async {
    owner.dispose();
    scope.dispose();
    await events.close();
    await TeamCubit.clearSessionCaches();
    await ChatMessageCacheStore.clearAllMemory();
    ChatMessageCacheStore.debugSetPrefs(null);
  });

  test('only exact mapping and a raw empty server page confirm empty',
      () async {
    final registry = VerifiedEmptyTeamChats();
    Future<void> probe(Object? map, Object? page) => verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () async => map,
        fetchPage: (_) async => page,
        isOpenAndEmpty: () => true);
    for (final page in [
      null,
      <Object>[{}],
      <Object>[
        {'id': 'message'}
      ]
    ]) {
      await probe([mapping()], page);
      expect(registry.lookup(scope, owner), isNull);
    }
    await probe([mapping(), mapping()], []);
    expect(registry.lookup(scope, owner), isNull);
    await probe([
      {'id': 'chat', 'team_id': 'other', 'type': 'team_main'}
    ], []);
    expect(registry.lookup(scope, owner), isNull);
    await probe([mapping()], []);
    expect(registry.lookup(scope, owner), 'chat');
  });

  test('new nonempty state invalidates delayed empty proof across cubits',
      () async {
    final registry = VerifiedEmptyTeamChats.instance;
    final page = Completer<Object?>();
    final started = Completer<void>();
    final work = verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () async => [mapping()],
        fetchPage: (_) {
          started.complete();
          return page.future;
        },
        isOpenAndEmpty: () => true);
    await started.future;
    final second = TeamCubit(team, repository: _Repository(), authScope: scope);
    second.emit(second.state.copyWith(chat: [
      Message(
        id: 'new',
        chatId: 'chat',
        authorId: 'a',
        authorLogin: '',
        authorName: '',
        text: 'new',
        at: DateTime.utc(2026),
      )
    ]));
    page.complete([]);
    await work;
    expect(registry.lookup(scope, owner), isNull);
    await second.close();
  });

  test('confirmed empty seeds a new actual cubit before network work',
      () async {
    final registry = VerifiedEmptyTeamChats.instance;
    await verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () async => [mapping()],
        fetchPage: (_) async => [],
        isOpenAndEmpty: () => true);
    final next = TeamCubit(team, repository: _Repository(), authScope: scope);
    expect(next.state.chatHasSnapshot, isTrue);
    expect(next.state.chatInitialLoading, isFalse);
    expect(next.state.chat, isEmpty);
    await next.close();
  });

  test('cached message takes precedence over confirmed empty', () async {
    final registry = VerifiedEmptyTeamChats.instance;
    TeamCubit.debugRememberEmptyTeamChat(team.id);
    await verifyEmptyTeamChat(
        registry: registry, scope: scope, owner: owner,
        fetchMapping: () async => [mapping()], fetchPage: (_) async => [],
        isOpenAndEmpty: () => true);
    await ChatMessageCacheStore.replace(chatId: 'chat', userId: 'a', messages: [
      Message(id: 'local', chatId: 'chat', authorId: 'a', authorLogin: '',
          authorName: '', text: 'pending', at: DateTime.utc(2026))
    ]);
    final next = TeamCubit(team, repository: _Repository(), authScope: scope);
    expect(next.state.chatHasSnapshot, isFalse);
    expect(registry.lookup(scope, owner), isNull);
    await next.close();
  });

  test('explicit access denial invalidates prior proof', () async {
    for (final code in ['42501', 'PGRST301', 'PGRST302', 'PT401', 'PT403']) {
      final registry = VerifiedEmptyTeamChats();
      registry.confirm(registry.begin(scope, owner)!, 'chat');
      await verifyEmptyTeamChat(
          registry: registry, scope: scope, owner: owner,
          fetchMapping: () async => throw PostgrestException(message: 'denied', code: code),
          fetchPage: (_) async => [], isOpenAndEmpty: () => true);
      expect(registry.lookup(scope, owner), isNull, reason: code);
    }
  });

  test('eviction and same-key reprobe prevent an old attempt from writing', () {
    final registry = VerifiedEmptyTeamChats(maxEntries: 1);
    final old = registry.begin(scope, owner)!;
    final other = TeamCacheOwner.bind(scope, 'other')!;
    registry.begin(scope, other);
    registry.begin(scope, owner);
    registry.confirm(old, 'chat');
    expect(registry.lookup(scope, owner), isNull);
    other.dispose();
  });

  test('old cohort cannot survive same-user logout and login', () {
    final registry = VerifiedEmptyTeamChats();
    registry.confirm(registry.begin(scope, owner)!, 'chat');
    events.add(const AuthState(AuthChangeEvent.signedOut, null));
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    final newOwner = TeamCacheOwner.bind(scope, team.id)!;
    expect(registry.lookup(scope, owner), isNull);
    expect(registry.lookup(scope, newOwner), isNull);
    newOwner.dispose();
  });

  test('owner from another scope with same user cannot create or read proof',
      () async {
    final otherEvents = StreamController<AuthState>.broadcast(sync: true);
    final otherScope = AuthSessionScope(
        currentSession: () => current, authEvents: otherEvents.stream);
    otherEvents.add(AuthState(AuthChangeEvent.initialSession, current));
    final registry = VerifiedEmptyTeamChats();
    expect(registry.begin(otherScope, owner), isNull);
    expect(registry.lookup(otherScope, owner), isNull);
    otherScope.dispose();
    await otherEvents.close();
  });

  test('closed or nonempty caller starts no network lookup', () async {
    var calls = 0;
    await verifyEmptyTeamChat(
      registry: VerifiedEmptyTeamChats(), scope: scope, owner: owner,
      fetchMapping: () async { calls++; return [mapping()]; },
      fetchPage: (_) async { calls++; return []; },
      isOpenAndEmpty: () => false,
    );
    expect(calls, 0);
  });

  test('token rotation invalidates old proof, but same cohort may reverify',
      () async {
    final registry = VerifiedEmptyTeamChats();
    final old = registry.begin(scope, owner)!;
    registry.confirm(old, 'chat');
    current = fakeSession('a', access: 'new-token');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    expect(registry.lookup(scope, owner), isNull);
    await verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () async => [mapping()],
        fetchPage: (_) async => [],
        isOpenAndEmpty: () => true);
    expect(registry.lookup(scope, owner), 'chat');
  });

  test('closed owner, denial and timeout never create a proof', () async {
    final registry = VerifiedEmptyTeamChats();
    final pending = Completer<Object?>();
    final work = verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () => pending.future,
        fetchPage: (_) async => [],
        isOpenAndEmpty: () => true,
        timeout: const Duration(milliseconds: 10));
    await work;
    pending.complete([mapping()]);
    expect(registry.lookup(scope, owner), isNull);
    await verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () async =>
            throw const PostgrestException(message: 'denied', code: '42501'),
        fetchPage: (_) async => [],
        isOpenAndEmpty: () => true);
    expect(registry.lookup(scope, owner), isNull);
    owner.dispose();
    await verifyEmptyTeamChat(
        registry: registry,
        scope: scope,
        owner: owner,
        fetchMapping: () async => [mapping()],
        fetchPage: (_) async => [],
        isOpenAndEmpty: () => true);
    expect(registry.lookup(scope, owner), isNull);
  });
}
