import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/data/chat_warm_coordinator.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('home warm coordinator populates scoped offline chat list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('chat_warm_qa_')))!;
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    const uid = 'warm-owner', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    var calls = 0;
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.invalid', publishableKey: 'qa',
      httpClient: MockClient((request) async {
        calls++;
        if (!request.url.path.endsWith('/rpc/get_my_chat_summaries')) {
          throw StateError('Unexpected QA RPC');
        }
        return http.Response(jsonEncode([{
          'chat_id': 'chat', 'chat_type': 'dm', 'peer_id': 'peer', 'title': 'Друг QA',
          'unread_count': 0, 'is_pinned': false, 'is_muted': false,
          'last_message_id': 'last', 'body': '__FG__:{"from":"source","items":[{"id":"one"},{"id":"two"}]}',
        }, {
          'chat_id': 'other', 'chat_type': 'dm', 'peer_id': 'peer2', 'title': 'Другой QA',
          'unread_count': 0, 'is_pinned': false, 'is_muted': false,
          'last_message_id': 'last2', 'body': 'Буквальный текст __FG__: не пересылка',
        }]), 200, request: request, headers: {'content-type': 'application/json'});
      }), authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false)));
    final client = Supabase.instance.client;
    await tester.runAsync(() => signInWithFileSession(client, uid, sid));
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
      authEvents: client.auth.onAuthStateChange);
    await tester.runAsync(() => scope.ready);
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://example.invalid/auth/v1',
      userId: uid, sessionId: sid, notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final db = (await tester.runAsync(() => openProjectChatServerDatabase(
      '${dir.path}/chat.db', factory: databaseFactoryFfi)))!;
    final cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://example.invalid');
    ProjectChatServerCache.qaInstance = cache;
    final owner = scope.capture()!;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => scope.isCurrent(owner));
    await tester.runAsync(() async {
      ChatWarmCoordinator.instance.start(barrier: barrier);
      await ChatWarmCoordinator.instance.refreshNow(force: true);
    });
    expect(calls, 1);
    ChatWarmCoordinator.instance.stop();
    expect(await tester.runAsync(() => barrier.closeAndDrain(timeout: const Duration(seconds: 1))), isTrue);
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(owner)!), isTrue);
    await tester.pumpWidget(MaterialApp(home: MyChatsScreen(cachedStore: cache, cachedCapabilities: caps)));
    for (var i = 0; i < 100 && find.text('Друг QA').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Друг QA'), findsOneWidget);
    expect(find.text('Пересланные сообщения (2)'), findsOneWidget);
    expect(find.textContaining('Буквальный текст __FG__: не пересылка'), findsOneWidget);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose(); scope.dispose(); ProjectChatServerCache.qaInstance = null;
    await tester.runAsync(() async {
      await db.close(); await Supabase.instance.dispose();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, target) || !p.basename(target).startsWith('chat_warm_qa_')) {
        throw StateError('Unsafe QA directory');
      }
      for (var i = 0; i < 40 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 50)); }
      }
      expect(await dir.exists(), isFalse);
    });
    messenger.setMockMethodCallHandler(links, null);
  });
}
