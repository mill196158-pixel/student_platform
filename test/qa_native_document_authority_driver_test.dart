import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/qa_native_document_authority.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('a committed revoked owner cannot start recovery', () async {
    final dir=await Directory.systemTemp.createTemp('qa-native-revoked-');
    final db=await openProjectChatServerDatabase('${dir.path}/db',factory:databaseFactoryFfi);
    addTearDown(() async { if(db.isOpen) await db.close(); await dir.delete(recursive:true); });
    final registry=DurableActiveSessionRegistry(db,'https://example.invalid'); await registry.initialize();
    final owner=captureProjectDatabaseOwner(db)!;
    final login=await registry.begin((await registry.read())!,nextUid:'u',nextSid:'s',current:()=>true);
    expect(await registry.finish(login!,current:()=>true,handoffOwner:owner),isTrue);
    await db.update('active_session_registry',{'state':'revoked'},where:'project=?',whereArgs:[registry.project]);
    final revoked=(await registry.read())!;
    const channel=MethodChannel('qa-native-revoked-test');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls=0;
    messenger.setMockMethodCallHandler(channel,(call) async { calls++; return true; });
    addTearDown(() => messenger.setMockMethodCallHandler(channel,null));
    final driver=QaNativeDocumentAuthorityDriver(db,owner,channel:channel);
    expect(await driver.recoverClosed(registry.project,'u','s',revoked),isFalse);
    expect(calls,0,reason:'revoked state must not reach native recovery');
    await db.close();
  });
  test('QA source proof sends exact identity and rejects a closed owner', () async {
    final dir=await Directory.systemTemp.createTemp('qa-native-proof-');
    final db=await openProjectChatServerDatabase('${dir.path}/db',factory:databaseFactoryFfi);
    addTearDown(() async { if(db.isOpen) await db.close(); await dir.delete(recursive:true); });
    final owner=captureProjectDatabaseOwner(db)!;
    const channel=MethodChannel('qa-native-proof-test');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final entered=Completer<void>(), release=Completer<void>();
    Map? captured;
    messenger.setMockMethodCallHandler(channel,(call) async {
      captured=call.arguments as Map;
      entered.complete(); await release.future;
      return 'a'*64;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel,null));
    const source=SourceAttachmentIdentity(project:'https://example.invalid',uid:'u',sid:'s',chatId:'c',messageId:'m',fileId:'f',fileKey:'k',fileUrl:'https://example.invalid/f');
    final driver=QaNativeDocumentAuthorityDriver(db,owner,channel:channel);
    final pending=driver.verifySource(source);
    await entered.future;
    expect(captured,{'project':source.project,'uid':'u','sid':'s','chat':'c','message':'m','file':'f','key':'k','url':source.fileUrl});
    await db.close();
    release.complete();
    expect(await pending,isNull);
  });
  test('uncertain native handoff never retries or exports', () async {
    final dir=await Directory.systemTemp.createTemp('qa-native-dispatch-');
    final db=await openProjectChatServerDatabase('${dir.path}/db',factory:databaseFactoryFfi);
    addTearDown(() async { if(db.isOpen) await db.close(); await dir.delete(recursive:true); });
    final owner=captureProjectDatabaseOwner(db)!;
    const channel=MethodChannel('qa-native-dispatch-test');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls=0;
    messenger.setMockMethodCallHandler(channel,(call) async { calls++; throw PlatformException(code:'unknown'); });
    addTearDown(() => messenger.setMockMethodCallHandler(channel,null));
    const source=SourceAttachmentIdentity(project:'https://example.invalid',uid:'u',sid:'s',chatId:'c',messageId:'m',fileId:'f',fileKey:'k',fileUrl:'https://example.invalid/f');
    final driver=QaNativeDocumentAuthorityDriver(db,owner,channel:channel);
    expect(await driver.dispatchSource(source,'synthetic_request_0001'),'uncertain');
    expect(calls,1);
    expect(await driver.dispatchSource(source,'bad'), 'blocked');
    expect(calls,1);
  });
  test('late native bind after guard close is abandoned', () async {
    final dir=await Directory.systemTemp.createTemp('qa-native-bind-');
    final db=await openProjectChatServerDatabase('${dir.path}/db',factory:databaseFactoryFfi);
    addTearDown(() async { if(db.isOpen) await db.close(); await dir.delete(recursive:true); });
    final registry=DurableActiveSessionRegistry(db,'https://example.invalid'); await registry.initialize();
    final owner=captureProjectDatabaseOwner(db)!;
    final login=await registry.begin((await registry.read())!,nextUid:'u',nextSid:'s',current:()=>true);
    expect(await registry.finish(login!,current:()=>true,handoffOwner:owner),isTrue);
    final snapshot=(await registry.read())!;
    const channel=MethodChannel('qa-native-bind-test');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final entered=Completer<void>(), release=Completer<void>();
    var closeCalls=0;
    messenger.setMockMethodCallHandler(channel,(call) async {
      if (call.method=='captureClosed') { entered.complete(); await release.future; return 'synthetic-ticket'; }
      if (call.method=='close') { closeCalls++; return true; }
      throw StateError('unexpected method');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel,null));
    final driver=QaNativeDocumentAuthorityDriver(db,owner,channel:channel);
    final capture=driver.captureClosed(registry.project,'u','s',snapshot);
    await entered.future;
    await db.close();
    release.complete();
    expect(await capture,isNull);
    expect(closeCalls,2,reason:'close-barrier and late-ticket cleanup both run');
  });
}
