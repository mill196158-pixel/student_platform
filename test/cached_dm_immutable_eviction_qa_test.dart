import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() async => initializeDateFormatting('ru'));

  testWidgets('cached DM fallback survives a stalled eviction and hides on revoke', (tester) async {
    expect(const bool.fromEnvironment('CHAT_HISTORY_SNAPSHOT_FALLBACK_QA'), isTrue,
        reason: 'Run this test with the explicit QA dart define');
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('cached-dm-eviction-')))!;
    final db = (await tester.runAsync(() => openProjectChatServerDatabase('${dir.path}/chat.db', factory: databaseFactoryFfi)))!;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1', userId: 'owner',
      sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final store = ProjectChatServerCache(db: db, scope: scope,
        currentBinding: () => binding, project: 'https://a.invalid');
    final message = Message(id: 'server', chatId: 'chat', authorId: 'owner',
      authorLogin: 'owner', authorName: 'Owner', text: 'Сохранённый текст', at: now);
    final ticket = (await tester.runAsync(() => store.begin('chat')))!;
    expect(await tester.runAsync(() => store.saveServerPage(ticket, [message], hasMore: false)), isTrue);
    final service = DmChatService.cachedOnly(peerId: 'peer', initialChatId: 'chat',
      capabilities: capabilities, cacheReader: (_, __) async =>
        ChatCacheSnapshot(found: true, messages: [message]));
    final entered = Completer<void>.sync(), release = Completer<void>.sync();
    store.debugBeforeHistoryEvictCommit = () async { entered.complete(); await release.future; };
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await service.dispose();
      capabilities.dispose(); scope.dispose(); await events.close();
      await tester.runAsync(() async {
        await db.close();
        if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) await dir.delete(recursive: true);
      });
    });
    await tester.pumpWidget(MaterialApp(home: UnifiedChatScreen(service: service, title: 'Чат')));
    await tester.pump();
    expect(find.text('Сохранённый текст'), findsOneWidget);
    late Future<ChatHistoryAppGuard?> eviction;
    await tester.runAsync(() async {
      eviction = store.beginHistoryAppGuard(1, allEnginesGuarded: true);
      await entered.future.timeout(const Duration(seconds: 5));
    });
    // Rebuild the existing route while the native transaction remains pending.
    await tester.pumpWidget(MaterialApp(home: UnifiedChatScreen(service: service, title: 'Чат')));
    await tester.pump();
    expect(find.text('Сохранённый текст'), findsOneWidget);
    capabilities.block();
    await tester.pump();
    expect(find.text('Сохранённый текст'), findsNothing);
    expect(find.text('Сохранённый чат недоступен.'), findsOneWidget);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final pendingReader = Completer<ChatCacheSnapshot>.sync();
    final notReady = DmChatService.cachedOnly(peerId: 'peer-2', initialChatId: 'chat-2',
        capabilities: capabilities, cacheReader: (_, __) => pendingReader.future);
    await tester.pumpWidget(MaterialApp(key: const ValueKey('not-ready'),
        home: UnifiedChatScreen(service: notReady, title: 'Другой чат')));
    await tester.pump();
    expect(find.text('Сохранённые сообщения временно недоступны.'), findsOneWidget);
    expect(find.text('Сообщений пока нет'), findsNothing);
    release.complete();
    final guard = await tester.runAsync(() => eviction);
    if (guard != null) await tester.runAsync(() => store.releaseHistoryAppGuard(guard));
    pendingReader.complete(ChatCacheSnapshot.notFound);
    await tester.pumpWidget(const SizedBox.shrink());
    await notReady.dispose();
  }, skip: !const bool.fromEnvironment('CHAT_HISTORY_SNAPSHOT_FALLBACK_QA'));
}
