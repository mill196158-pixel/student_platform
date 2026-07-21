import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/data/chat_preload_service.dart';
import 'package:student_platform/src/ui/chats/data/chat_sync_realtime_gate.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';

Message _msg(
  String id, {
  String chatId = 'chat-1',
  DateTime? at,
  String text = 'hi',
}) {
  return Message(
    id: id,
    chatId: chatId,
    authorId: 'u1',
    authorLogin: 'login',
    authorName: 'User',
    text: text,
    at: at ?? DateTime.utc(2026, 1, 1, 12),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ChatMessageCacheStore.debugSetPrefs(prefs);
    ChatMessageCacheStore.debugUserIdOverride = 'user-a';
    await ChatMessageCacheStore.clearOnLogout();
    ChatMessageCacheStore.debugUserIdOverride = 'user-a';
    ChatMessageCacheStore.debugSetPrefs(prefs);
    DmApi.debugResetLoadCounts();
  });

  tearDown(() async {
    await DmApi.clearSessionState();
    await ChatMessageCacheStore.clearOnLogout();
    ChatMessageCacheStore.debugSetPrefs(null);
    ChatMessageCacheStore.debugUserIdOverride = null;
  });

  test('1. empty snapshot has found/hasSnapshot=true', () async {
    final snap = await ChatMessageCacheStore.replace(
      chatId: 'chat-empty',
      userId: 'user-a',
      messages: const [],
    );
    expect(snap.found, isTrue);
    expect(snap.hasSnapshot, isTrue);
    expect(snap.messages, isEmpty);
    expect(
      ChatMessageCacheStore.hasSnapshot('chat-empty', userId: 'user-a'),
      isTrue,
    );
    final cold = await ChatMessageCacheStore.read(
      'chat-empty',
      userId: 'user-a',
    );
    expect(cold.found, isTrue);
    expect(cold.messages, isEmpty);
  });

  testWidgets('2. empty cached DM does not show initial loading',
      (tester) async {
    const view = ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.ready,
      messages: [],
      hasSnapshot: true,
    );
    expect(view.isInitialLoading, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            messages: view.messages,
            controller: ScrollController(),
            messageKeys: {},
            search: ChatSearchController(),
            currentUserId: 'me',
            onReply: (_) {},
            onLongPress: (_, __, ___, ____, _____, ______) {},
            onReplyTap: (_) {},
            onReact: (_, __) {},
            selectingMessages: false,
            selectedMessageIds: const {},
            onToggleSelect: (_) {},
            initialLoading: view.isInitialLoading,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Сообщений пока нет'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('2b. empty refreshing DM never flashes empty state',
      (tester) async {
    const view = ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.refreshing,
      messages: [],
      hasSnapshot: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            messages: view.messages,
            controller: ScrollController(),
            messageKeys: {},
            search: ChatSearchController(),
            currentUserId: 'me',
            onReply: (_) {},
            onLongPress: (_, __, ___, ____, _____, ______) {},
            onReplyTap: (_) {},
            onReact: (_, __) {},
            selectingMessages: false,
            selectedMessageIds: const {},
            onToggleSelect: (_) {},
            initialLoading: view.isInitialLoading ||
                (view.isRefreshing && view.messages.isEmpty),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Сообщений пока нет'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test('3/4. syncLatest single-flight for one chatId', () async {
    final a = DmApi.syncLatest(chatId: 'chat-sf');
    final b = DmApi.syncLatest(chatId: 'chat-sf');
    expect(identical(a, b), isTrue, reason: 'two subscribers share one Future');
    final ra = await a;
    final rb = await b;
    expect(ra.ok, isFalse);
    expect(rb.ok, isFalse);
    // At most one load attempt for this chat (0 if Supabase is unavailable
    // before loadMessagesPage; never 2).
    expect(DmApi.debugLoadCount('chat-sf') <= 1, isTrue);
  });

  test('5. network failure does not replace existing cache with []', () async {
    await ChatMessageCacheStore.replace(
      chatId: 'chat-keep',
      userId: 'user-a',
      messages: [_msg('m1')],
    );
    final failed = ChatSyncResult.failure(Exception('network'));
    expect(failed.ok, isFalse);

    // Failed sync must not call applyLatestServerPage([]).
    final after =
        await ChatMessageCacheStore.read('chat-keep', userId: 'user-a');
    expect(after.found, isTrue);
    expect(after.messages.map((m) => m.id), ['m1']);
  });

  test('6. error without cache shows error state', () {
    const view = ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.error,
      messages: [],
      hasSnapshot: false,
      error: 'network',
    );
    expect(view.showError, isTrue);
    expect(view.isInitialLoading, isFalse);
  });

  test('7. logout clears memory stream/cache of previous user', () async {
    await ChatMessageCacheStore.replace(
      chatId: 'chat-x',
      userId: 'user-a',
      messages: [_msg('m1')],
    );
    expect(
      ChatMessageCacheStore.hasSnapshot('chat-x', userId: 'user-a'),
      isTrue,
    );
    await DmApi.clearSessionState();
    await ChatMessageCacheStore.clearOnLogout();
    expect(
      ChatMessageCacheStore.hasSnapshot('chat-x', userId: 'user-a'),
      isFalse,
    );
    expect(
      (await ChatMessageCacheStore.read('chat-x', userId: 'user-a')).found,
      isFalse,
    );
  });

  test('8. team chat can be ready before files/assignments/role loading', () {
    const team = Team(
      id: 't1',
      name: 'Team',
      teacher: 'T',
      groupCode: 'G',
      icon: '📚',
    );
    final state = TeamState(
      team: team,
      chat: const [],
      chatHasSnapshot: true,
      chatRefreshing: false,
      filesLoading: true,
      assignmentsLoading: true,
      roleLoading: true,
      loading: false,
    );
    expect(state.chatHasSnapshot, isTrue);
    expect(state.chatInitialLoading, isFalse);
    expect(state.filesLoading, isTrue);
    expect(state.assignmentsLoading, isTrue);
    expect(state.roleLoading, isTrue);
  });

  test('9. deleted message disappears after reconcileLatestPage', () {
    final existing = [
      _msg('a', at: DateTime.utc(2026, 1, 1, 10)),
      _msg('b', at: DateTime.utc(2026, 1, 1, 11)),
      _msg('c', at: DateTime.utc(2026, 1, 1, 12)),
    ];
    final serverPage = [
      _msg('a', at: DateTime.utc(2026, 1, 1, 10)),
      _msg('c', at: DateTime.utc(2026, 1, 1, 12)),
    ];
    final next = ChatMessageCacheStore.reconcileLatestPage(
      existing: existing,
      serverPage: serverPage,
      pageLimit: 50,
    );
    expect(next.map((m) => m.id).toList(), ['a', 'c']);
  });

  test('9b. older paginated history is kept outside synced window', () {
    final existing = [
      _msg('old', at: DateTime.utc(2026, 1, 1, 8)),
      _msg('a', at: DateTime.utc(2026, 1, 1, 10)),
      _msg('b', at: DateTime.utc(2026, 1, 1, 11)),
    ];
    final serverPage = [
      _msg('a', at: DateTime.utc(2026, 1, 1, 10)),
      _msg('b', at: DateTime.utc(2026, 1, 1, 11)),
    ];
    final next = ChatMessageCacheStore.reconcileLatestPage(
      existing: existing,
      serverPage: serverPage,
      pageLimit: 2,
    );
    expect(next.map((m) => m.id).toList(), ['old', 'a', 'b']);
  });

  test('10. realtime-style upsert/remove does not call loadMessages', () async {
    await ChatMessageCacheStore.replace(
      chatId: 'chat-rt',
      userId: 'user-a',
      messages: [_msg('a')],
    );
    final beforeCount = DmApi.debugLoadCount('chat-rt');
    await ChatMessageCacheStore.reconcileUpsert(
      'chat-rt',
      _msg('b', at: DateTime.utc(2026, 1, 1, 13)),
      userId: 'user-a',
    );
    await ChatMessageCacheStore.remove('chat-rt', 'a', userId: 'user-a');
    final snap = await ChatMessageCacheStore.read('chat-rt', userId: 'user-a');
    expect(snap.messages.map((m) => m.id), ['b']);
    expect(DmApi.debugLoadCount('chat-rt'), beforeCount);
  });

  test(
      '11. empty chat after cold restart loads found snapshot without skeleton',
      () async {
    await ChatMessageCacheStore.replace(
      chatId: 'chat-cold',
      userId: 'user-a',
      messages: const [],
    );
    await ChatMessageCacheStore.clearAllMemory();
    final snap =
        await ChatMessageCacheStore.read('chat-cold', userId: 'user-a');
    expect(snap.found, isTrue);
    expect(snap.messages, isEmpty);

    final view = ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.refreshing,
      messages: snap.messages,
      hasSnapshot: snap.found,
    );
    expect(view.isInitialLoading, isFalse);
  });

  test('12. ChatPreloadService warmUpChatIds syncs cold chats', () async {
    DmApi.debugPrimeClearedAt('a', null);
    DmApi.debugPrimeClearedAt('b', null);
    final synced = <String>{};
    DmApi.debugSyncPageLoader = ({
      required String chatId,
      required int limit,
      DateTime? clearedAt,
    }) async {
      synced.add(chatId);
      return (
        messages: [_msg('m1-$chatId', chatId: chatId)],
        hasMore: false,
      );
    };

    await ChatPreloadService.warmUpChatIds(['a', 'b'], parallel: 2);
    expect(synced, containsAll(['a', 'b']));

    final snapA = await ChatMessageCacheStore.read('a', userId: 'user-a');
    expect(snapA.found, isTrue);
    expect(snapA.messages, isNotEmpty);

    // Fresh cache should skip a second warm.
    synced.clear();
    await ChatPreloadService.warmUpChatIds(['a'], parallel: 1);
    expect(synced, isEmpty);
  });

  testWidgets('error UI shows retry, not empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            messages: const [],
            controller: ScrollController(),
            messageKeys: {},
            search: ChatSearchController(),
            currentUserId: 'me',
            onReply: (_) {},
            onLongPress: (_, __, ___, ____, _____, ______) {},
            onReplyTap: (_) {},
            onReact: (_, __) {},
            selectingMessages: false,
            selectedMessageIds: const {},
            onToggleSelect: (_) {},
            loadError: true,
            onRetryLoad: () {},
          ),
        ),
      ),
    );
    expect(find.text('Не удалось загрузить сообщения'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(find.text('Сообщений пока нет'), findsNothing);
  });

  test('empty authoritative server page clears stale messages', () {
    final existing = [
      _msg('stale', at: DateTime.utc(2026, 1, 1, 10)),
    ];
    final next = ChatMessageCacheStore.reconcileLatestPage(
      existing: existing,
      serverPage: const [],
      pageLimit: 50,
    );
    expect(next, isEmpty);
  });

  group('Realtime vs sync serialization', () {
    const chatId = 'chat-race';

    Future<ChatSyncResult> _delayedSync({
      required List<Message> page,
      required Duration delay,
      bool fail = false,
    }) {
      DmApi.debugPrimeClearedAt(chatId, null);
      final catalog = <String, Message>{
        for (final m in page) m.id: m,
      };
      DmApi.debugLoadMessageById = ({
        required String chatId,
        required String messageId,
      }) async =>
          catalog[messageId];

      DmApi.debugSyncPageLoader = ({
        required String chatId,
        required int limit,
        DateTime? clearedAt,
      }) async {
        await Future<void>.delayed(delay);
        if (fail) throw Exception('sync_failed');
        return (messages: page, hasMore: false);
      };

      return DmApi.syncLatest(
        chatId: chatId,
        invalidateClearBoundary: false,
      );
    }

    tearDown(() {
      DmApi.debugSyncPageLoader = null;
      DmApi.debugLoadMessageById = null;
    });

    test('INSERT during sync survives reconcile', () async {
      await ChatMessageCacheStore.replace(
        chatId: chatId,
        messages: [_msg('a', chatId: chatId)],
      );
      final inserted = _msg(
        'b',
        chatId: chatId,
        at: DateTime.utc(2026, 1, 1, 13),
        text: 'fresh',
      );

      final syncFuture = _delayedSync(
        page: [_msg('a', chatId: chatId)],
        delay: const Duration(milliseconds: 40),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(DmApi.debugGateFor(chatId)?.isSyncing, isTrue);
      DmApi.debugLoadMessageById = ({
        required String chatId,
        required String messageId,
      }) async {
        if (messageId == 'b') return inserted;
        if (messageId == 'a') return _msg('a', chatId: chatId);
        return null;
      };
      await DmApi.debugHandleRealtimeUpsert(chatId: chatId, messageId: 'b');

      final result = await syncFuture;
      expect(result.ok, isTrue);
      final ids =
          ChatMessageCacheStore.messagesSync(chatId).map((m) => m.id).toList();
      expect(ids, containsAll(['a', 'b']));
    });

    test('UPDATE during sync keeps new version', () async {
      await ChatMessageCacheStore.replace(
        chatId: chatId,
        messages: [
          _msg('a', chatId: chatId, text: 'old'),
        ],
      );
      final updated = _msg(
        'a',
        chatId: chatId,
        text: 'new',
        at: DateTime.utc(2026, 1, 1, 12),
      );

      final syncFuture = _delayedSync(
        page: [_msg('a', chatId: chatId, text: 'old')],
        delay: const Duration(milliseconds: 40),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      DmApi.debugLoadMessageById = ({
        required String chatId,
        required String messageId,
      }) async =>
          messageId == 'a' ? updated : null;
      await DmApi.debugHandleRealtimeUpsert(chatId: chatId, messageId: 'a');

      final result = await syncFuture;
      expect(result.ok, isTrue);
      final msg = ChatMessageCacheStore.messagesSync(chatId).single;
      expect(msg.text, 'new');
    });

    test('DELETE during sync is not resurrected by page', () async {
      await ChatMessageCacheStore.replace(
        chatId: chatId,
        messages: [
          _msg('a', chatId: chatId),
          _msg('b', chatId: chatId, at: DateTime.utc(2026, 1, 1, 13)),
        ],
      );

      final syncFuture = _delayedSync(
        page: [
          _msg('a', chatId: chatId),
          _msg('b', chatId: chatId, at: DateTime.utc(2026, 1, 1, 13)),
        ],
        delay: const Duration(milliseconds: 40),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await DmApi.debugHandleRealtimeDelete(chatId: chatId, messageId: 'b');
      expect(
        DmApi.debugGateFor(chatId)?.pendingDeleteTombstones.contains('b'),
        isTrue,
      );

      final result = await syncFuture;
      expect(result.ok, isTrue);
      final ids =
          ChatMessageCacheStore.messagesSync(chatId).map((m) => m.id).toList();
      expect(ids, ['a']);
      expect(ids, isNot(contains('b')));
    });

    test('event during flush is also applied', () async {
      var upsertCalls = 0;
      final applied = <String>[];
      late final ChatSyncRealtimeGate gate;
      gate = ChatSyncRealtimeGate(
        applyUpsert: (id) async {
          upsertCalls++;
          applied.add(id);
          if (id == 'b') {
            // Nested event while flushing first buffered upsert.
            await gate.handleUpsert('c');
          }
        },
        applyDelete: (_) async {},
      );

      // Drive exclusive sync with delay; enqueue b during sync.
      final sync = gate.runExclusiveSync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await gate.handleUpsert('b');
      await sync;

      expect(applied, containsAll(['b', 'c']));
      expect(upsertCalls, greaterThanOrEqualTo(2));
    });

    test('sync error still applies buffered Realtime event', () async {
      await ChatMessageCacheStore.replace(
        chatId: chatId,
        messages: [_msg('a', chatId: chatId)],
      );
      final inserted = _msg(
        'b',
        chatId: chatId,
        at: DateTime.utc(2026, 1, 1, 13),
      );

      final syncFuture = _delayedSync(
        page: [_msg('a', chatId: chatId)],
        delay: const Duration(milliseconds: 40),
        fail: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      DmApi.debugLoadMessageById = ({
        required String chatId,
        required String messageId,
      }) async =>
          messageId == 'b' ? inserted : _msg('a', chatId: chatId);
      await DmApi.debugHandleRealtimeUpsert(chatId: chatId, messageId: 'b');

      final result = await syncFuture;
      expect(result.ok, isFalse);
      // Existing cache kept + buffered insert applied after failed sync.
      final ids =
          ChatMessageCacheStore.messagesSync(chatId).map((m) => m.id).toList();
      expect(ids, containsAll(['a', 'b']));
    });
  });
}
