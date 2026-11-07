import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('session switch fences cached reads and lease stays until in-flight read drains', () async {
    final root = await Directory.systemTemp.createTemp('project-media-session-');
    final db = await openProjectChatServerDatabase('${root.path}/history.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    var auth = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => auth, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, auth));
    final now = DateTime.now().toUtc();
    var binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1', userId: 'a',
      sessionId: 'sid-a', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://a.invalid');
    addTearDown(() async {
      scope.dispose(); await events.close(); await db.close();
      if (root.parent.absolute.path == Directory.systemTemp.absolute.path) await root.delete(recursive: true);
    });
    final session = (await cache.openMediaProtection(root))!;
    expect(session.isCurrent, isTrue);
    final started = Completer<void>(), finish = Completer<void>();
    final read = session.store.readInOwnerWindow('a', () => true, () async {
      started.complete(); await finish.future; return 'private';
    });
    await started.future;
    auth = fakeSession('b');
    binding = OfflineSessionBinding(issuer: binding.issuer, userId: 'b', sessionId: 'sid-b',
      notBefore: binding.notBefore, expiresAt: binding.expiresAt);
    events.add(AuthState(AuthChangeEvent.signedIn, auth));
    expect(session.isCurrent, isFalse);
    final closing = session.close();
    expect(await db.query('media_cache_read_leases'), hasLength(1));
    finish.complete();
    await expectLater(read, throwsStateError);
    await closing;
    expect(await db.query('media_cache_read_leases'), isEmpty);
  });
}
