import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/services/qa_receipt_probe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('real cache path retains pending, deny and in-flight logout fencing', () async {
  SharedPreferences.setMockInitialValues({});
  final dir=await Directory.systemTemp.createTemp('qa-probe-linked-');
  const channel=MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => dir.path);
  var requests=0;
  await Supabase.initialize(url:'https://example.test',publishableKey:'test',httpClient:MockClient((_) async {requests++;throw const SocketException('offline');}),authOptions:const FlutterAuthClientOptions(autoRefreshToken:false));
  addTearDown(() async {
   ChatFileAccess.debugAfterQaReceiptProbe=null;
   await Supabase.instance.dispose();
   TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null);
   if (await dir.exists()) {
    final root=await Directory.systemTemp.resolveSymbolicLinks(); final actual=await dir.resolveSymbolicLinks();
    if(!p.isWithin(root,actual)||!p.basename(actual).startsWith('qa-probe-linked-')) throw StateError('Unsafe test cleanup');
    await dir.delete(recursive:true);
   }
  });
  const uid='qa-probe-owner', sid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const url='https://studentsplatform.storage.yandexcloud.net/chats/test/probe.png';
  await signInWithFileSession(Supabase.instance.client,uid,sid);
  final digest=sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
  final file=File('${dir.path}/authorized_chat_files/$uid/$digest');
  await file.parent.create(recursive:true); await file.writeAsBytes([1,2,3]);
  final grant=File('${file.path}.grant'), pending=File('${file.path}.pending'), denied=File('${file.path}.denied');
  await grant.writeAsString('chat-file-grant-v2:$sid');
  final seen=<QaReceiptProbeResult>[];
  ChatFileAccess.debugAfterQaReceiptProbe=(result) async { seen.add(result); };
  expect(await ChatFileAccess.readCachedOnly(url,permit:()=>true),[1,2,3]);
  const enabled=bool.fromEnvironment('QA_RECEIPT_ISOLATE');
  expect(seen.isNotEmpty,enabled);
  await grant.rename(pending.path); ChatFileAccess.debugResetProcessMemory();
  expect(await ChatFileAccess.readCachedOnly(url,permit:()=>true),isNull);
  if(enabled) expect(seen,contains(QaReceiptProbeResult.pending));
  await pending.rename(grant.path); await denied.writeAsString('revoked');
  expect(await ChatFileAccess.readCachedOnly(url,permit:()=>true),isNull);
  await denied.delete();
  if(enabled) {
   final enteredAba=Completer<void>(), releaseAba=Completer<void>();
   ChatFileAccess.debugAfterQaReceiptProbe=(result) async { if(!enteredAba.isCompleted) {enteredAba.complete(); await releaseAba.future;} };
   final stale=ChatFileAccess.readCachedOnly(url,permit:()=>true);
   await enteredAba.future.timeout(const Duration(seconds:5));
   await signInWithFileSession(Supabase.instance.client,'other-owner','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
   await signInWithFileSession(Supabase.instance.client,uid,sid);
   releaseAba.complete();
   expect(await stale,isNull);
   final entered=Completer<void>(), release=Completer<void>();
   ChatFileAccess.debugAfterQaReceiptProbe=(result) async { if(!entered.isCompleted) {entered.complete(); await release.future;} };
   final read=ChatFileAccess.readCachedOnly(url,permit:()=>true);
   await entered.future.timeout(const Duration(seconds:5));
   ChatFileAccess.fenceForLogout();
   release.complete();
   expect(await read,isNull);
  }
  expect(await file.readAsBytes(),[1,2,3]); expect(requests,0);
 });
}
