import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _PausedCache extends ProjectChatServerCache {
  _PausedCache(
      {required super.db,
      required super.scope,
      required super.currentBinding,
      required super.project});
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<ProjectChatPageTicket?> begin(String chat,
      {bool Function()? isCurrent}) async {
    final ticket = await super.begin(chat, isCurrent: isCurrent);
    entered.complete();
    await release.future;
    return ticket;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'stale same-user credential cannot dispatch confirmed page after delayed begin',
      () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(links, (_) async => null);
    await Supabase.initialize(
        url: 'https://example.invalid',
        publishableKey: 'test',
        httpClient: MockClient(
            (request) async => http.Response('[]', 200, request: request)),
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final dir = await Directory.systemTemp.createTemp('dm-snapshot-race-');
    final db = await openProjectChatServerDatabase('${dir.path}/chat.db',
        factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a', access: 'session-a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(
        issuer: 'https://example.invalid/auth/v1',
        userId: 'a',
        sessionId: 'sid-a',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    final cache = _PausedCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://example.invalid');
    ProjectChatServerCache.qaInstance = cache;
    ChatMessageCacheStore.debugUserIdOverride = 'a';
    DmApi.debugPrimeClearedAt('chat', null);
    DmApi.debugSyncPageLoader = (
            {required chatId, required limit, clearedAt}) async =>
        (messages: <Message>[], hasMore: false);
    var dispatched = 0;
    DmApi.debugConfirmedPageLoader =
        ({required chatId, required limit, clearedAt}) async {
      dispatched++;
      return const ConfirmedDmPage([], false, ConfirmedDmSource.serverRpc);
    };
    final sync =
        DmApi.syncLatest(chatId: 'chat', invalidateClearBoundary: false);
    await cache.entered.future.timeout(const Duration(seconds: 10));
    // No auth event: the captured scope must notice the changed getter itself.
    session = fakeSession('a', access: 'session-b');
    cache.release.complete();
    await sync;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(dispatched, 0);
    session = fakeSession('a', access: 'session-a');
    final nextCache = _PausedCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://example.invalid');
    ProjectChatServerCache.qaInstance = nextCache;
    final fetched = Completer<void>();
    DmApi.debugConfirmedPageLoader =
        ({required chatId, required limit, clearedAt}) async {
      dispatched++;
      fetched.complete();
      return const ConfirmedDmPage([], false, ConfirmedDmSource.serverRpc);
    };
    final secondSync =
        DmApi.syncLatest(chatId: 'chat', invalidateClearBoundary: false);
    await nextCache.entered.future.timeout(const Duration(seconds: 10));
    nextCache.release.complete();
    await fetched.future.timeout(const Duration(seconds: 10));
    await secondSync;
    expect(dispatched, 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    DmApi.debugConfirmedPageLoader = null;
    DmApi.debugSyncPageLoader = null;
    ProjectChatServerCache.qaInstance = null;
    ChatMessageCacheStore.debugUserIdOverride = null;
    await DmApi.clearSessionState();
    scope.dispose();
    await events.close();
    await db.close();
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(links, null);
    final target = await dir.resolveSymbolicLinks();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    if (!path.isWithin(root, target) ||
        !path.basename(target).startsWith('dm-snapshot-race-'))
      throw StateError('Unsafe QA path');
    await dir.delete(recursive: true);
  });
}
