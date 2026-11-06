import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/data/confirmed_summary_warmup.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('confirmed home warmup saves scoped list; stale, malformed and closed work cannot replace it', () async {
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('summary_warm_qa_');
    var db = await openProjectChatServerDatabase('${dir.path}/chat.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://example.invalid/auth/v1',
      userId: 'owner', sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    var cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://example.invalid');
    final owner = scope.capture()!;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => scope.isCurrent(owner));
    final caps = SessionCapabilities(scope);
    Map<String, dynamic> raw(String id) => {'chat_id': id, 'chat_type': 'dm',
      'unread_count': 0, 'is_pinned': false, 'is_muted': false, 'peer_id': 'peer'};
    Map<String, dynamic>? mapRow(Map<String, dynamic> row) => {
      'team': {'id': '', 'name': 'Peer', 'teacher': '', 'groupCode': '', 'icon': ''},
      'title': 'Peer', 'chatId': row['chat_id'], 'isDm': true, 'peerId': row['peer_id'],
      'unread': 0, 'pinned': false, 'muted': false};
    var calls = 0;
    Future<bool> warm(Future<Object?> Function() fetch) => warmConfirmedSummaries(
      cache: cache, barrier: barrier, isCurrent: () => scope.isCurrent(owner),
      fetch: fetch, mapRow: mapRow);
    expect(await warm(() async { calls++; return [raw('original')]; }), isTrue);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(owner)!), isTrue);
    expect((await cache.readSummaries(caps))!.single['chatId'], 'original');
    expect(await warm(() async { calls++; return [raw('new'), {'chat_id': 'bad'}]; }), isFalse);
    expect((await cache.readSummaries(caps))!.single['chatId'], 'original');
    // The visible MyChats request starts first; background must not advance
    // the sequence and silently make the foreground result stale.
    final foreground = (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
    expect(await warmConfirmedSummaries(cache: cache, barrier: barrier,
      isCurrent: () => false, fetch: () async { calls++; return [raw('warm')]; },
      mapRow: mapRow), isFalse);
    expect(await cache.saveSummaries(foreground, [mapRow(raw('foreground'))!]), isTrue);
    expect((await cache.readSummaries(caps))!.single['chatId'], 'foreground');
    // A queued SQLite transaction must recheck that the list did not open
    // while warmup waited for the database lock.
    final entered = Completer<void>(), release = Completer<void>();
    final holder = db.transaction((_) async { entered.complete(); await release.future; });
    await entered.future;
    var listOpened = false;
    final queuedWarm = warmConfirmedSummaries(cache: cache, barrier: barrier,
      isCurrent: () => !listOpened, fetch: () async { calls++; return [raw('warm')]; },
      mapRow: mapRow);
    await Future<void>.delayed(Duration.zero);
    listOpened = true;
    final foregroundAfter = cache.begin(ProjectChatServerCache.summaryChatKey);
    release.complete();
    await holder;
    expect(await queuedWarm, isFalse);
    final currentForeground = (await foregroundAfter)!;
    expect(await cache.saveSummaries(currentForeground, [mapRow(raw('foreground'))!]), isTrue);
    // The foreground can open while the background insert is still awaiting
    // commit. The transaction must roll that replacement back, including
    // after reopening the actual SQLite database.
    final inserted = Completer<void>(), finishWrite = Completer<void>();
    cache.debugBeforeSummaryCommit = () async { inserted.complete(); await finishWrite.future; };
    var foregroundOpened = false;
    final pausedWarm = warmConfirmedSummaries(cache: cache, barrier: barrier,
      isCurrent: () => !foregroundOpened,
      fetch: () async => [raw('must-not-commit')], mapRow: mapRow);
    await inserted.future;
    foregroundOpened = true;
    finishWrite.complete();
    expect(await pausedWarm, isFalse);
    cache.debugBeforeSummaryCommit = null;
    await db.close();
    db = await openProjectChatServerDatabase('${dir.path}/chat.db', factory: databaseFactoryFfi);
    cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://example.invalid');
    expect((await cache.readSummaries(caps))!.single['chatId'], 'foreground');
    final pending = Completer<Object?>();
    final attempt = warm(() { calls++; return pending.future; });
    while (calls < 3) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
    expect(await barrier.closeAndDrain(timeout: const Duration(milliseconds: 5)), isFalse);
    pending.complete([raw('late')]);
    expect(await attempt, isFalse);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
    expect((await cache.readSummaries(caps))!.single['chatId'], 'foreground');
    expect(await warm(() async { calls++; return [raw('blocked')]; }), isFalse);
    expect(calls, 3);
    session = fakeSession('other');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await cache.readSummaries(caps), isNull);
    caps.dispose(); scope.dispose(); await events.close(); await db.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final target = await dir.resolveSymbolicLinks();
    if (!p.isWithin(root, target) || !p.basename(target).startsWith('summary_warm_qa_')) {
      throw StateError('Unsafe QA directory');
    }
    await dir.delete(recursive: true);
  });
}
