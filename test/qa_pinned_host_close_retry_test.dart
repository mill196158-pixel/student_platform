import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/pinned_media_host.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('host retains exact DB handle after native close fails and retries it', () async {
    final root=await Directory.systemTemp.createTemp('qa-host-close-');
    final events=StreamController<AuthState>.broadcast(sync:true);
    final scope=AuthSessionScope(currentSession:()=>null,authEvents:events.stream);
    final ready=Completer<Database>();
    var allow=false,calls=0;
    final host=PinnedMediaHost(scope:scope,project:'https://example.invalid',currentSession:()=>null,
      currentBinding:()=>null,supportDirectory:() async => root,cacheDirectory:() async => root,
      databaseFactory:databaseFactoryFfi,onQaGuardReady:(db) async {
        final owner=captureProjectDatabaseOwner(db)!;
        expect(registerQaNativeCloseBarrier(db,owner,() async { calls++; return allow; }),isTrue);
        ready.complete(db);
      })..start();
    final db=await ready.future;
    await expectLater(host.dispose(),throwsStateError);
    expect(db.isOpen,isTrue);
    allow=true;
    await host.dispose();
    expect((db.isOpen,calls),(false,2));
    scope.dispose(); await events.close(); await root.delete(recursive:true);
  });
  test('QA recovery consumes guard evidence before dead-handle cleanup', () async {
    final root=await Directory.systemTemp.createTemp('qa-host-order-');
    final events=StreamController<AuthState>.broadcast(sync:true);
    final session=fakeSession('u');
    final scope=AuthSessionScope(currentSession:()=>session,authEvents:events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession,session));
    await scope.ready;
    final now=DateTime.now().toUtc();
    final binding=OfflineSessionBinding(issuer:'https://example.invalid/auth/v1',userId:'u',
      sessionId:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',notBefore:now.subtract(const Duration(hours:1)),expiresAt:now.add(const Duration(hours:1)));
    final entered=Completer<void>(), proceed=Completer<void>(), cleanup=Completer<void>();
    debugBeforePinnedRecovery=() async { if(!cleanup.isCompleted) cleanup.complete(); };
    final host=PinnedMediaHost(scope:scope,project:'https://example.invalid',currentSession:()=>session,
      currentBinding:()=>binding,supportDirectory:() async=>root,cacheDirectory:() async=>root,
      databaseFactory:databaseFactoryFfi,onQaGuardReady:(_) async { entered.complete(); await proceed.future; })..start();
    addTearDown(() async { debugBeforePinnedRecovery=null; await host.dispose(); scope.dispose(); await events.close(); await root.delete(recursive:true); });
    await entered.future;
    await Future<void>.delayed(const Duration(milliseconds:50));
    expect(cleanup.isCompleted,isFalse);
    proceed.complete();
    await cleanup.future.timeout(const Duration(seconds:3));
  });
}
