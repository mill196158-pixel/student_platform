// Separate Android package; only fabricated documents and identities.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

@pragma('vm:entry-point')
Future<void> secondaryEngineMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('student_platform/source_document_qa_secondary');
  const channel = MethodChannel('student_platform/source_document_qa_guard');
  try {
    final args = await control.invokeMapMethod<String,dynamic>('getInput');
    if (args == null) throw StateError('missing synthetic fixture args');
    final claim = await channel.invokeMethod<bool>('claimNativeOwnerSynthetic',args);
    final dispatch = await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',args);
    await control.invokeMethod<void>('report',{'claim':claim,'dispatch':dispatch});
  } catch (_) {
    await control.invokeMethod<void>('report',{'failed':true});
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid || (await PackageInfo.fromPlatform()).packageName != 'com.mill453020.studentplatform.attachfixture') throw StateError('Isolated fixture only');
  final support = await getApplicationSupportDirectory();
  final root = Directory('${support.path}/qa_native_fixture_v9');
  if (await root.exists()) throw StateError('Fresh isolated fixture data required');
  await root.create();
  final mediaPath = '${root.path}/media.db', chatPath = '${root.path}/chat.db';
  final media = await openDatabase(mediaPath), chat = await openDatabase(chatPath);
  await media.execute('CREATE TABLE source_bound_documents(project TEXT,uid TEXT,sid TEXT,chat TEXT,message TEXT,file TEXT,key TEXT,url TEXT,sha TEXT,bytes BLOB)');
  await media.execute('CREATE TABLE source_bound_proofs(project TEXT,uid TEXT,sid TEXT,chat TEXT,message TEXT,file TEXT,revision INTEGER,sha TEXT)');
  await media.execute('CREATE TABLE pinned_fence_state(id TEXT,revision INTEGER,denied INTEGER,dirty INTEGER,content_hash TEXT)');
  await media.execute('CREATE TABLE pinned_fence_pending(token TEXT,id TEXT)');
  await media.execute('CREATE TABLE media_cache_logout_tombstones(project TEXT,uid TEXT,sid TEXT)');
  await media.execute('CREATE TABLE active_session_registry(project TEXT,instance TEXT,revision INTEGER,uid TEXT,sid TEXT,state TEXT,owner_engine TEXT)');
  await chat.execute('CREATE TABLE chat_server_attempt(project TEXT,uid TEXT,sid TEXT,chat TEXT,seq INTEGER,blocked INTEGER)');
  await chat.execute('CREATE TABLE chat_server_snapshot(project TEXT,uid TEXT,sid TEXT,chat TEXT,payload TEXT)');
  String part(Object input) => base64Url.encode(utf8.encode(jsonEncode(input))).replaceAll('=', '');
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  var syntheticLogoutCalls = 0;
  final sdk = SupabaseClient('https://example.invalid','synthetic',
      httpClient:MockClient((request) async {
        if (request.method != 'POST' || request.url.origin != 'https://example.invalid' ||
            request.url.path != '/auth/v1/logout' || request.url.queryParameters.length != 1 ||
            request.url.queryParameters['scope'] != 'local') throw StateError('unexpected synthetic request');
        syntheticLogoutCalls++;
        return http.Response('',204);
      }),
      authOptions:const AuthClientOptions(autoRefreshToken:false));
  await sdk.auth.setInitialSession(jsonEncode({'access_token':'${part({'alg':'HS256'})}.${part({'sub':'synthetic','session_id':'synthetic-session','exp':exp})}.sig',
    'refresh_token':'synthetic','token_type':'bearer','expires_at':exp,
    'user':{'id':'synthetic','aud':'authenticated','app_metadata':{},'user_metadata':{},'created_at':'2020-01-01T00:00:00Z'}}));
  final src = {'project':'https://example.invalid','uid':sdk.auth.currentUser!.id,'sid':'synthetic-session','chat':'c','message':'m','file':'f','key':'k','url':'https://example.invalid/f'};
  await media.insert('active_session_registry',{'project':src['project'],'instance':'qa-instance','revision':1,'uid':src['uid'],'sid':src['sid'],'state':'active'});
  final bytes = Uint8List.fromList(List<int>.generate(3 * 1024 * 1024, (i) => i % 251));
  final sha = sha256.convert(bytes).toString();
  final fence = sha256.convert(utf8.encode(jsonEncode([src['project'],src['uid'],src['key']]))).toString();
  final common = {for(final key in ['project','uid','sid','chat','message','file']) key:src[key]};
  await media.insert('source_bound_documents',{...common,'key':src['key'],'url':src['url'],'sha':sha,'bytes':bytes});
  await media.insert('source_bound_proofs',{...common,'revision':1,'sha':sha});
  await media.insert('pinned_fence_state',{'id':fence,'revision':1,'denied':0,'dirty':0,'content_hash':sha});
  final chatCommon = {for(final key in ['project','uid','sid','chat']) key:src[key]};
  await chat.insert('chat_server_attempt',{...chatCommon,'seq':1,'blocked':0});
  final file = {'id':'f','chat_id':'c','message_id':'m','file_key':'k','file_url':src['url'],'is_deleted':false,'deletion_verified':true};
  await chat.insert('chat_server_snapshot',{...chatCommon,'payload':jsonEncode([{'id':'m','chat_id':'c','client_id':null,'delivery_status':'sent','attachments':[file]}])});
  const channel = MethodChannel('student_platform/source_document_qa_guard');
  Future<bool> check() async => await channel.invokeMethod<bool>('verifyRealSchemaSynthetic', {...src,'media':mediaPath,'chatDb':chatPath}) ?? false;
  final args = {...src,'media':mediaPath,'chatDb':chatPath};
  String status;
  var stage = 'START';
  try {
    stage = 'VALID_PROOF';
    if (!await check()) throw StateError('valid synthetic source rejected');
    stage = 'SECONDARY_CLAIM';
    if (await channel.invokeMethod<bool>('claimOtherEngineSynthetic',{...args,'media':'${support.path}/fake.db'}) != false) throw StateError('second engine claimed owner');
    stage = 'SECONDARY_DART_BEFORE_OWNER';
    final before = await channel.invokeMapMethod<String,dynamic>('runDartSecondarySynthetic',{...args,'request':'secondary_before_owner_01'});
    if (before?['claim'] != false || before?['dispatch'] != 'blocked') throw StateError('secondary dart engine was not fenced');
    stage = 'PRIMARY_CONTENDER';
    if (await channel.invokeMethod<bool>('claimPrimaryContenderSynthetic',args) != false) throw StateError('second primary claimed owner');
    stage = 'PRIMARY_CLAIM';
    if (await channel.invokeMethod<bool>('claimNativeOwnerSynthetic',args) != true) throw StateError('owner claim rejected');
    stage = 'SECONDARY_DART_AFTER_OWNER';
    final after = await channel.invokeMapMethod<String,dynamic>('runDartSecondarySynthetic',{...args,'request':'secondary_after_owner_001'});
    if (after?['claim'] != false || after?['dispatch'] != 'blocked') throw StateError('secondary dart engine was not fenced');
    stage = 'SECONDARY_DISPATCH';
    final second = await channel.invokeMethod<String>('dispatchOtherEngineSynthetic',{...args,'request':'other_engine_request_0001'});
    if (second != 'blocked') throw StateError('second engine was not fenced');
    final stolen = await media.query('qa_docx_dispatch',where:'request=?',whereArgs:['other_engine_request_0001']);
    if (stolen.isNotEmpty) throw StateError('second engine reserved an id');
    stage = 'DENIED_PROOF';
    await media.update('pinned_fence_state',{'denied':1});
    if (await check()) throw StateError('denied source accepted');
    stage = 'DENIED_REPLAY';
    final denied = await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',{...args,'request':'denied_source_request_001'});
    final replay = await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',{...args,'request':'denied_source_request_001'});
    if (denied != 'uncertain' || replay != 'uncertain') throw StateError('reserved request replayed');
    stage = 'CORRUPT_PROOF';
    await media.update('pinned_fence_state',{'denied':0});
    await media.update('source_bound_documents',{'bytes':Uint8List.fromList([1,2,3])});
    if (await check()) throw StateError('changed bytes accepted');
    await media.update('source_bound_documents',{'bytes':bytes});
    const preparedRequest = 'prepared_source_request_001';
    stage = 'PREPARE_SNAPSHOT';
    final prepared = await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',{...args,'request':preparedRequest,'prepareOnly':true});
    if (prepared != 'prepared') throw StateError('snapshot not prepared');
    stage = 'PIPE_LIMIT_TIMEOUT';
    if (await channel.invokeMethod<bool>('holdPreparedSynthetic',{'request':preparedRequest}) != true) throw StateError('pipe concurrency unbounded');
    await Future<void>.delayed(const Duration(milliseconds:150));
    stage = 'PROVIDER_READ';
    final read = await channel.invokeMethod<String>('readPreparedSynthetic',{'request':preparedRequest});
    if (read != sha) throw StateError('system provider returned wrong bytes');
    stage = 'SEEK_AND_SLOW';
    if (await channel.invokeMethod<bool>('seekPreparedSynthetic',{'request':preparedRequest}) != true) throw StateError('seekable slow reader failed');
    stage = 'DENIED_REOPEN';
    await media.update('pinned_fence_state',{'denied':1});
    if (await channel.invokeMethod<String>('readPreparedSynthetic',{'request':preparedRequest}) != null) throw StateError('provider reopened after denial');
    await media.update('pinned_fence_state',{'denied':0});
    stage = 'REVISION_FENCE';
    await media.update('active_session_registry',{'revision':2});
    if (await channel.invokeMethod<bool>('claimNativeOwnerSynthetic',args) != false) throw StateError('stale revision reclaimed');
    if (await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',{...args,'request':'stale_revision_request_01'}) != 'blocked') throw StateError('stale revision dispatched');
    await media.update('active_session_registry',{'revision':1});
    stage = 'SDK_LOGOUT_FENCE';
    await media.update('active_session_registry',{'state':'revoked'});
    await sdk.auth.signOut(scope:SignOutScope.local);
    if (sdk.auth.currentSession != null || syntheticLogoutCalls != 1) throw StateError('synthetic sdk logout failed');
    if (await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',{...args,'request':'sdk_logout_fence_request_01'}) != 'blocked') throw StateError('post-logout dispatch allowed');
    if (await channel.invokeMethod<String>('readPreparedSynthetic',{'request':preparedRequest}) != null) throw StateError('post-logout provider open allowed');
    stage = 'NATIVE_RESTART_FENCE';
    await media.update('active_session_registry',{'state':'active'});
    if (await channel.invokeMethod<String>('dispatchRealSchemaSynthetic',{...args,'request':'pre_restart_prepare_0001','prepareOnly':true}) != 'prepared') throw StateError('pre-restart owner unavailable');
    if (await channel.invokeMethod<bool>('restartNativeOwnerSynthetic',args) != false) throw StateError('restart adopted old owner');
    if (await channel.invokeMethod<bool>('claimNativeOwnerSynthetic',args) != false) throw StateError('old owner replayed after restart');
    status = 'SYNTHETIC_SOURCE_PROOF_PASS';
  } catch (error) { status = 'SYNTHETIC_SOURCE_PROOF_FAIL stage=$stage type=${error.runtimeType}'; }
  await sdk.dispose();
  debugPrint(status);
  runApp(MaterialApp(home: Scaffold(body: Center(child:Text(status)))));
}
