// Isolated two-process Android fixture. Uses only synthetic sessions; no network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/local_snapshot_startup.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/qa_document_authority_host.dart';
import 'package:student_platform/src/core/qa_native_document_authority.dart';
import 'package:student_platform/src/core/qa_native_project_guard.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _session() {
  final now=DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String p(Object x)=>base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
  final access='${p({'alg':'HS256'})}.${p({'iss':'https://example.invalid/auth/v1','sub':'synthetic','session_id':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','role':'authenticated','aud':'authenticated','iat':now-3600,'exp':now-120})}.sig';
  return jsonEncode({'access_token':access,'refresh_token':'synthetic','token_type':'bearer',
    'user':{'id':'synthetic','aud':'authenticated','app_metadata':{},'user_metadata':{},'created_at':'2020-01-01T00:00:00Z'}});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final package=(await PackageInfo.fromPlatform()).packageName;
  final denyFixture=package=='com.mill453020.studentplatform.authorityrecoverdenyfixture';
  final sourceFixture=package=='com.mill453020.studentplatform.authoritysourcefixture' || package=='com.mill453020.studentplatform.authoritysourcediagnosticv6';
  final revokedFixture=package=='com.mill453020.studentplatform.authorityrecoverrevokedfixture';
  if (!Platform.isAndroid || (!denyFixture && !revokedFixture && !sourceFixture && package!='com.mill453020.studentplatform.authorityrecoverfixture' && package!='com.mill453020.studentplatform.authorityrecoverdiagnosticfixture')) throw StateError('isolated fixture only');
  final root=await getApplicationSupportDirectory();
  final path='${root.path}/pinned_media_guard_ordinary_v1.db';
  if (await File(path).exists()) throw StateError('fresh fixture required');
  final seed=await openProjectChatServerDatabase(path);
  final initial=DurableActiveSessionRegistry(seed,'https://example.invalid'); await initial.initialize(); await seed.close();
  const control=MethodChannel('student_platform/authority_recovery_fixture');
  var stage='START_OWNER'; String status;
  void mark(String value) { stage=value; debugPrint('AUTHORITY_STAGE $value'); }
  Future<T> bounded<T>(Future<T> task) => task.timeout(const Duration(seconds:8));
  mark(stage);
  try {
    if (await control.invokeMethod<bool>('startOwner')!=true) throw StateError('start failed');
    mark('OPEN_DB_GUARD');
    final db=await openProjectChatServerDatabase(path,qaNativeGuard:QaNativeProjectGuard.acquire);
    mark('WAIT_OWNER');
    final registry=DurableActiveSessionRegistry(db,'https://example.invalid');
    for(var i=0;i<200;i++) {
      final state=await registry.read();
      if(state?.state=='active') break;
      await Future<void>.delayed(const Duration(milliseconds:10));
    }
    final old=(await registry.read())!;
    if(old.state!='active') throw StateError('owner not ready');
    mark('OWNER_READY');
    final guard=captureProjectDatabaseOwner(db)!;
    final driver=QaNativeDocumentAuthorityDriver(db,guard);
    const sid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    mark('LIVE_LEASE_REJECT');
    if(await driver.recoverClosed(registry.project,'synthetic',sid,old)) throw StateError('live owner recovered');
    Future<void> lockMode(String value) async {
      if(await control.invokeMethod<bool>('setLockMode',{'mode':value})!=true) throw StateError('lock mode rejected');
      for(var i=0;i<200;i++) {
        if((await db.query('qa_recovery_fixture')).single['mode']==value) return;
        await Future<void>.delayed(const Duration(milliseconds:10));
      }
      throw StateError('lock mode timeout');
    }
    for(final mode in ['guardOnly','docOnly']) {
      mark('LOCK_$mode');
      await lockMode(mode);
      if(await driver.recoverClosed(registry.project,'synthetic',sid,old)) throw StateError('partial live lock recovered');
      await lockMode('both');
    }
    mark('REVOKED_REJECT');
    await db.update('active_session_registry',{'state':'revoked'},where:'project=?',whereArgs:[registry.project]);
    if(await driver.recoverClosed(registry.project,'synthetic',sid,old)) throw StateError('revoked owner recovered');
    // Restore fabricated fixture row solely to exercise the independent crash scenario.
    if (!revokedFixture) await db.update('active_session_registry',{'state':'active'},where:'project=?',whereArgs:[registry.project]);
    mark('KILL_SYNTHETIC_OWNER');
    if(await control.invokeMethod<bool>('killOwner')!=true) throw StateError('kill failed');
    if (revokedFixture) {
      mark('REVOKED_AFTER_KILL');
      var dead=false;
      for(var i=0;i<200 && !dead;i++) {
        dead=await control.invokeMethod<bool>('ownerDead')==true;
        if(!dead) await Future<void>.delayed(const Duration(milliseconds:10));
      }
      if(!dead) throw StateError('owner death not confirmed');
      if(await driver.recoverClosed(registry.project,'synthetic',sid,old)) throw StateError('revoked crash recovered');
      if((await registry.read())?.state!='revoked') throw StateError('revocation lost');
      await db.close();
      status='AUTHORITY_COLD_RECOVERY_REVOKED_PASS';
    } else {
    mark('RECOVER_CAS');
    var recovered=false;
    for(var i=0;i<100 && !recovered;i++) {
      final outcomes=await bounded(Future.wait([driver.recoverClosed(registry.project,'synthetic',sid,old),driver.recoverClosed(registry.project,'synthetic',sid,old)]));
      if (outcomes.where((x)=>x).length>1) throw StateError('concurrent recovery double-admitted');
      recovered=outcomes.any((x)=>x);
      if(!recovered) await Future<void>.delayed(const Duration(milliseconds:20));
    }
    if(!recovered) throw StateError('dead lease recovery failed');
    final current=(await registry.read())!;
    if(current.revision!=old.revision+1 || current.state!='active') throw StateError('bad recovery epoch');
    final rows=await db.query('qa_native_document_authority_v2');
    if(rows.single['state']!='closed') throw StateError('recovery opened document');
    if (denyFixture) {
      mark('TOMBSTONE_AFTER_RECOVERY');
      await db.insert('media_cache_logout_tombstones',{'project':registry.project,'uid':'synthetic','sid':sid});
    }
    mark('CACHE_ONLY');
    var network=0;
    final inner=MockClient((_) async { network++; throw StateError('network forbidden'); });
    final gate=RefreshAdmissionClient(inner,backend:Uri.parse(registry.project),qaAuthorityRequired:true)..bind(inner);
    final sdk=SupabaseClient(registry.project,'synthetic',httpClient:gate,authOptions:const AuthClientOptions(autoRefreshToken:false));
    await sdk.auth.setInitialSession(_session());
    final scope=AuthSessionScope(currentSession:()=>sdk.auth.currentSession,authEvents:sdk.auth.onAuthStateChange); await scope.ready;
    final host=QaDocumentAuthorityHost(client:sdk,scope:scope,gate:gate,registry:registry,owner:guard,native:driver,
      policy:SettledPolicyTransport.forTesting(inner,Uri.parse(registry.project)),publicKey:'synthetic');
    final caps=SessionCapabilities(scope);
    final latch=QaCachedAdmissionLatch();
    final startup=LocalSnapshotStartup(scope:scope,issuer:'${registry.project}/auth/v1',
      restore:() async=>SessionRestoreStatus.transportFailure,
      checkPolicy:() async=>throw StateError('network forbidden'),
      onCacheOnlyGranted:latch.onGranted);
    if(await startup.resolve(caps)!=OfflineStartupResult.cacheOnly) throw StateError('cache permit failed');
    if(!await bounded(host.prepare())) throw StateError('host failed');
    latch.bind(host);
    final result=await bounded(latch.lastAttempt!);
    if (result==denyFixture) throw StateError('cache admission outcome');
    if (network!=0) throw StateError('cache admission used network');
    if((await db.query('qa_native_document_authority_v2')).single['state']!=(denyFixture ? 'closed' : 'open')) throw StateError('cache authority mismatch');
    if (!denyFixture) {
      mark('DOUBLE_GRANT');
      latch.onGranted(caps);
      if(!await bounded(latch.lastAttempt!)) throw StateError('repeat cache grant failed');
      if((await db.query('qa_native_document_authority_v2')).single['state']!='open') throw StateError('repeat grant revoked authority');
      if (sourceFixture) {
        mark('SOURCE_PROOF');
        final chat=await openDatabase('${await getDatabasesPath()}/offline_chat_ordinary_v1.db');
        mark('SOURCE_SCHEMA');
        await db.execute('CREATE TABLE source_bound_documents(project TEXT,uid TEXT,sid TEXT,chat TEXT,message TEXT,file TEXT,key TEXT,url TEXT,sha TEXT,bytes BLOB)');
        await db.execute('CREATE TABLE source_bound_proofs(project TEXT,uid TEXT,sid TEXT,chat TEXT,message TEXT,file TEXT,revision INTEGER,sha TEXT)');
        await db.execute('CREATE TABLE pinned_fence_state(id TEXT,revision INTEGER,denied INTEGER,dirty INTEGER,content_hash TEXT)');
        await db.execute('CREATE TABLE pinned_fence_pending(token TEXT,id TEXT,database_token TEXT)');
        await chat.execute('CREATE TABLE chat_server_attempt(project TEXT,uid TEXT,sid TEXT,chat TEXT,seq INTEGER,blocked INTEGER)');
        await chat.execute('CREATE TABLE chat_server_snapshot(project TEXT,uid TEXT,sid TEXT,chat TEXT,payload TEXT)');
        const src=SourceAttachmentIdentity(project:'https://example.invalid',uid:'synthetic',sid:sid,chatId:'c',messageId:'m',fileId:'f',fileKey:'k',fileUrl:'https://example.invalid/f');
        final bytes=Uint8List.fromList(List<int>.generate(3*1024*1024,(i)=>i%251));
        final hash=sha256.convert(bytes).toString();
        final fence=sha256.convert(utf8.encode(jsonEncode([src.project,src.uid,src.fileKey]))).toString();
        final common={'project':src.project,'uid':src.uid,'sid':src.sid,'chat':src.chatId,'message':src.messageId,'file':src.fileId};
        mark('SOURCE_SEED');
        await db.insert('source_bound_documents',{...common,'key':src.fileKey,'url':src.fileUrl,'sha':hash,'bytes':bytes});
        await db.insert('source_bound_proofs',{...common,'revision':1,'sha':hash});
        await db.insert('pinned_fence_state',{'id':fence,'revision':1,'denied':0,'dirty':0,'content_hash':hash});
        final chatCommon={'project':src.project,'uid':src.uid,'sid':src.sid,'chat':src.chatId};
        await chat.insert('chat_server_attempt',{...chatCommon,'seq':1,'blocked':0});
        final file={'id':'f','chat_id':'c','message_id':'m','file_key':'k','file_url':src.fileUrl,'is_deleted':false,'deletion_verified':true};
        await chat.insert('chat_server_snapshot',{...chatCommon,'payload':jsonEncode([{'id':'m','chat_id':'c','client_id':null,'delivery_status':'sent','attachments':[file]}])});
        mark('SOURCE_VERIFY');
        if(await bounded(driver.verifySource(src))!=hash) throw StateError('source proof rejected');
        mark('SOURCE_TOMBSTONE');
        await db.insert('media_cache_logout_tombstones',{'project':src.project,'uid':src.uid,'sid':src.sid});
        if(await bounded(driver.verifySource(src))!=null) throw StateError('revoked proof accepted');
        await db.delete('media_cache_logout_tombstones',where:'project=? AND uid=? AND sid=?',whereArgs:[src.project,src.uid,src.sid]);
        await chat.close();
      }
      mark('LOGOUT_FENCE');
      if(!await bounded(host.revokeBeforeLogout())) throw StateError('close failed');
      mark('LOGOUT_REGISTRY');
      if((await registry.read())?.state!='revoked') throw StateError('logout not committed');
      mark('LOGOUT_NO_RECOVERY');
      if(await driver.recoverClosed(registry.project,'synthetic',sid,(await registry.read())!)) throw StateError('revoked recovery allowed');
    }
    mark('CLEANUP_SCOPE');
    caps.dispose(); scope.dispose();
    mark('CLEANUP_SDK');
    await bounded(sdk.dispose());
    mark('CLEANUP_DB');
    await bounded(db.close());
    status=denyFixture ? 'AUTHORITY_COLD_RECOVERY_DENY_PASS' : 'AUTHORITY_COLD_RECOVERY_PASS';
    }
  } catch(error) { status='AUTHORITY_COLD_RECOVERY_FAIL stage=$stage type=${error.runtimeType}'; }
  debugPrint(status);
  runApp(MaterialApp(home:Scaffold(body:Center(child:Text(status)))));
}
