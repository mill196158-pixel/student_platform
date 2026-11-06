import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/data/chat_archive_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real WAL: durable sequence rejects older response after reopen',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('student_chat_sqlite_');
    final path = '${dir.path}/pages.db';
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(
        issuer: 'https://a.invalid/auth/v1',
        userId: 'a',
        sessionId: 'sid',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var db =
        await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    ProjectChatServerCache make() => ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    var cache = make();
    Message msg(String id, int hour) => Message.fromJson({
          'id': id,
          'chat_id': 'chat',
          'author_id': 'a',
          'content': id,
          'created_at': DateTime.utc(2026, 1, 1, hour).toIso8601String()
        });
    final old = (await cache.begin('chat'))!;
    final secondDb =
        await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final secondCoordinator = ProjectChatServerCache(
        db: secondDb,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    final newer = (await secondCoordinator.begin('chat'))!;
    expect(
        await secondCoordinator.saveServerPage(newer, [msg('latest', 2)],
            hasMore: false),
        isTrue);
    expect(
        await cache.saveServerPage(old, [msg('obsolete', 1)], hasMore: false),
        isFalse);
    await secondDb.close();
    await db.close();
    db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    cache = make();
    final cap = SessionCapabilities(scope);
    expect(
        cap.grant(SessionCapabilityMode.cacheOnly,
            cap.beginAuthorization(scope.capture()!)!),
        isTrue);
    expect((await cache.read('chat', cap))!.single.id, 'latest');
    final summaryTicket =
        (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
    expect(
        await cache.saveSummaries(summaryTicket, [
          {
            'team': {
              'id': '',
              'name': 'Peer',
              'teacher': '',
              'groupCode': '',
              'icon': ''
            },
            'title': 'Peer',
            'chatId': 'chat',
            'isDm': true,
            'peerId': 'peer',
            'unread': 0,
            'pinned': false,
            'muted': false,
          }
        ]),
        isTrue);
    expect((await cache.readSummaries(cap))!.single['title'], 'Peer');
    final foreign = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://b.invalid');
    expect(await foreign.readSummaries(cap), isNull);
    final pending = (await cache.begin('chat'))!;
    expect(await cache.invalidate('chat'), isTrue);
    expect(
        await cache.saveServerPage(pending, [msg('obsolete', 1)],
            hasMore: false),
        isFalse);
    expect(await cache.read('chat', cap), isNull);
    await db.close();
    db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    cache = make();
    expect(await cache.read('chat', cap), isNull);
    expect(
        await cache.saveServerPage((await cache.begin('chat'))!, [],
            hasMore: false),
        isTrue);
    expect(await cache.read('chat', cap), isEmpty);
    final oldPage = (await cache.begin('chat'))!;
    final oldSummary =
        (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
    final entered = Completer<void>();
    final response = Completer<void>();
    var cleared = false;
    final hide = ChatArchiveApi.hidePersonalChatWith(
        chatId: 'chat',
        cache: cache,
        remoteHide: () {
          entered.complete();
          return response.future;
        },
        clearLocal: () {
          cleared = true;
        });
    await entered.future;
    expect(await cache.read('chat', cap), isNull);
    expect(await cache.begin('chat'), isNull);
    expect(await cache.begin(ProjectChatServerCache.summaryChatKey), isNull);
    expect(
        await cache.saveSummaries(oldSummary, [
          {
            'team': {
              'id': '',
              'name': 'Peer',
              'teacher': '',
              'groupCode': '',
              'icon': ''
            },
            'title': 'Hidden',
            'chatId': 'chat',
            'isDm': true,
            'peerId': 'peer',
            'unread': 0,
            'pinned': false,
            'muted': false
          }
        ]),
        isFalse);
    expect(await cache.readSummaries(cap), isNull);
    expect(await cache.saveServerPage(oldPage, [msg('old', 1)], hasMore: false),
        isFalse);
    response.complete();
    await hide;
    expect(cleared, isTrue);
    expect(await cache.read('chat', cap), isNull);
    expect(
        await cache.saveServerPage(
            (await cache.begin('chat'))!, [msg('new', 3)],
            hasMore: false),
        isTrue);
    expect((await cache.read('chat', cap))!.single.id, 'new');
    cleared = false;
    final otherBinding = OfflineSessionBinding(
        issuer: 'https://b.invalid/auth/v1',
        userId: 'a',
        sessionId: 'sid',
        notBefore: binding.notBefore,
        expiresAt: binding.expiresAt);
    var otherStore = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => otherBinding,
        project: 'https://b.invalid');
    await expectLater(
        ChatArchiveApi.hidePersonalChatWith(
            chatId: 'other',
            cache: otherStore,
            remoteHide: () async => throw StateError('failed'),
            clearLocal: () {
              cleared = true;
            }),
        throwsA(isA<StateError>()));
    expect(cleared, isFalse);
    await expectLater(
        ChatArchiveApi.hidePersonalChatWith(
            chatId: 'chat',
            cache: cache,
            remoteHide: () async => throw TimeoutException('unknown'),
            clearLocal: () {
              cleared = true;
            }),
        throwsA(isA<TimeoutException>()));
    expect(cleared, isFalse);
    await db.close();
    db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    cache = make();
    expect(await cache.begin('chat'), isNull);
    otherStore = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => otherBinding,
        project: 'https://b.invalid');
    expect(await otherStore.begin('other'), isNull);
    expect(await cache.read('chat', cap), isNull);
    cap.dispose();
    scope.dispose();
    await events.close();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  });
}
