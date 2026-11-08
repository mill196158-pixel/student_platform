import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/qa_document_authority_host.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'experimental_guarded_supabase_initialize_test.dart' as fixture;

class TestNative implements QaNativeDocumentAuthority {
  final ticket=Object(); bool closed=false,opened=false,allowClose=true;
  @override Future<Object?> captureClosed(String project,String uid,String sid,ActiveSessionSnapshot owner) async {
    if (project!='https://example.invalid' || uid!='u') return null;
    closed=true; return ticket;
  }
  @override Future<bool> admit(Object value,ActiveSessionSnapshot owner) async {
    if (!identical(value,ticket) || !closed || owner.state!='active' || owner.uid!='u') return false;
    opened=true; return true;
  }
  @override Future<bool> abandon(Object value) async { if (!identical(value,ticket) || !allowClose) return false; closed=true; opened=false; return true; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('late denial route waits for committed close and failure does not route', () async {
    final closing=Completer<bool>();
    var routed=false;
    final first=qaRevokeThenRoute(()=>closing.future,()=>routed=true);
    await Future<void>.delayed(Duration.zero);
    expect(routed,isFalse);
    closing.complete(false);
    expect(await first,isFalse);
    expect(routed,isFalse);
    expect(await qaRevokeThenRoute(() async => true,()=>routed=true),isTrue);
    expect(routed,isTrue);
  });
  for (final mode in ['allowed','denied','cached','cached-stale']) {
    test('document authority follows SDK and admission: $mode', () async {
      final allow=mode=='allowed';
      final dir=await Directory.systemTemp.createTemp('qa-authority-host-');
      final db=await openProjectChatServerDatabase('${dir.path}/db',factory:databaseFactoryFfi);
      addTearDown(() async { await db.close(); await dir.delete(recursive:true); });
      final registry=DurableActiveSessionRegistry(db,'https://example.invalid'); await registry.initialize();
      final owner=captureProjectDatabaseOwner(db)!;
      const sid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      final login=await registry.begin((await registry.read())!,nextUid:'u',nextSid:sid,current:()=>true);
      expect(await registry.finish(login!,current:()=>true,handoffOwner:owner),isTrue);
      var refreshes=0, policyRequests=0;
      final inner=MockClient((request) async { refreshes++; return http.Response(fixture.session('new'),200,headers:{'content-type':'application/json'}); });
      final gate=RefreshAdmissionClient(inner,backend:Uri.parse('https://example.invalid'),qaAuthorityRequired:true);
      gate.bind(inner);
      final sdk=SupabaseClient('https://example.invalid','synthetic',httpClient:gate,authOptions:const AuthClientOptions(autoRefreshToken:false));
      addTearDown(sdk.dispose);
      final old=jsonDecode(fixture.session('old')) as Map<String,dynamic>;
      final now=DateTime.now().millisecondsSinceEpoch ~/ 1000;
      String part(Object x)=>base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
      old['access_token']='${part({'alg':'HS256'})}.${part({'iss':'https://example.invalid/auth/v1','sub':'u','session_id':sid,'role':'authenticated','aud':'authenticated','iat':now-3600,'exp':now-120})}.sig';
      await sdk.auth.setInitialSession(jsonEncode(old));
      final scope=AuthSessionScope(currentSession:()=>sdk.auth.currentSession,authEvents:sdk.auth.onAuthStateChange);
      await scope.ready;
      final native=TestNative();
      final allowedResponse=Completer<http.Response>();
      final transport=SettledPolicyTransport.forTesting(MockClient((request) async {
        policyRequests++;
        return allow ? allowedResponse.future : http.Response('',403);
      }),Uri.parse('https://example.invalid'));
      final host=QaDocumentAuthorityHost(client:sdk,scope:scope,gate:gate,registry:registry,owner:owner,
          native:native,policy:transport,publicKey:'synthetic');
      addTearDown(() async { await host.dispose(); scope.dispose(); });
      final latch=QaCachedAdmissionLatch();
      SessionCapabilities? earlyCaps;
      if (mode.startsWith('cached')) {
        earlyCaps=SessionCapabilities(scope);
        final early=earlyCaps.beginAuthorization(scope.capture()!)!;
        expect(earlyCaps.grant(SessionCapabilityMode.cacheOnly,early),isTrue);
        latch.onGranted(earlyCaps);
        expect(native.opened,isFalse);
      }
      expect(await host.prepare(),isTrue);
      expect(native.closed,isTrue); expect(native.opened,isFalse);
      if (mode=='cached-stale') {
        scope.invalidateForSignOut();
        latch.bind(host);
        expect(await latch.lastAttempt,isFalse);
        expect(native.opened,isFalse);
        expect((refreshes,policyRequests),(0,0));
        earlyCaps!.dispose();
        return;
      }
      if (mode=='cached') {
        for (final variant in ['same','issuer','uid']) {
          final foreignJson=jsonDecode(fixture.session('foreign')) as Map<String,dynamic>;
          final uid=variant=='uid' ? 'other' : 'u';
          final issuer=variant=='issuer' ? 'https://other.invalid/auth/v1' : 'https://example.invalid/auth/v1';
          foreignJson['access_token']='${part({'alg':'HS256'})}.${part({'iss':issuer,'sub':uid,'session_id':sid,'role':'authenticated','aud':'authenticated','iat':now-60,'exp':now+3600})}.sig';
          (foreignJson['user'] as Map)['id']=uid;
          final foreignSession=Session.fromJson(foreignJson)!;
          final foreignEvents=StreamController<AuthState>.broadcast(sync:true);
          final foreignScope=AuthSessionScope(currentSession:()=>foreignSession,authEvents:foreignEvents.stream);
          foreignEvents.add(AuthState(AuthChangeEvent.initialSession,foreignSession));
          final foreignCaps=SessionCapabilities(foreignScope);
          final foreignAttempt=foreignCaps.beginAuthorization(foreignScope.capture()!)!;
          expect(foreignCaps.grant(SessionCapabilityMode.cacheOnly,foreignAttempt),isTrue);
          expect(await host.admitCached(foreignCaps),isFalse,reason:'foreign scope: $variant');
          expect(native.opened,isFalse);
          foreignCaps.dispose(); foreignScope.dispose(); await foreignEvents.close();
        }
        final caps=earlyCaps!;
        latch.bind(host);
        for(var i=0;i<100 && !native.opened;i++) {
          await Future<void>.delayed(const Duration(milliseconds:5));
        }
        expect((refreshes,policyRequests),(0,0));
        expect(native.opened,isTrue);
        latch.onGranted(caps);
        expect(await latch.lastAttempt,isTrue);
        expect(native.opened,isTrue,reason:'repeated grant must preserve existing authority');
        scope.invalidateForSignOut();
        expect(await host.admitCached(caps),isFalse);
        caps.dispose();
        return;
      }
      expect((await sdk.auth.refreshSession()).session?.refreshToken,'new');
      expect((await registry.read())?.state,'transition');
      expect(native.opened,isFalse);
      if (allow) {
        final first=host.admitAfterPolicy();
        await Future<void>.delayed(Duration.zero);
        expect(await host.admitAfterPolicy(),isFalse,reason:'no second policy request may overtake the first');
        allowedResponse.complete(http.Response('[{"id":"u","must_change_password":false}]',200));
        expect(await first,isTrue);
      } else { expect(await host.admitAfterPolicy(),isFalse); }
      expect((refreshes,policyRequests),(1,1));
      expect(native.opened,allow);
      expect((await registry.read())?.state,allow ? 'active' : 'transition');
      if (allow) {
        native.allowClose=false;
        var routed=false;
        expect(await qaRevokeThenRoute(QaDocumentAuthorityLifecycle.revokeBeforeLogout,()=>routed=true),isFalse);
        expect(routed,isFalse);
        expect(native.opened,isTrue,reason:'failed native commit is not reported as closed');
        native.allowClose=true;
        expect(await QaDocumentAuthorityLifecycle.revokeBeforeLogout(),isTrue);
        expect(native.opened,isFalse);
        await sdk.auth.signOut(scope:SignOutScope.local);
        expect(sdk.auth.currentSession,isNull);
      }
    });
  }
}
