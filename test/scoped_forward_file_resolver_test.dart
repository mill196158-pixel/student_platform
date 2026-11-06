import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/scoped_forward_file_resolver.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class Store implements ProjectChatServerCache {
  Store(this.scope);
  @override final AuthSessionScope scope;
  List<Message>? rows;
  Completer<List<Message>?>? gate;
  @override Future<List<Message>?> read(String chat, SessionCapabilities caps) async => gate == null ? rows : gate!.future;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
void main() {
 test('exact source, file identity, denial and stale session', () async {
  final events = StreamController<AuthState>.broadcast(sync:true);
  var session = fakeSession('a');
  final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
  events.add(AuthState(AuthChangeEvent.initialSession,session));
  final caps = SessionCapabilities(scope);
  void allow() => expect(caps.grant(SessionCapabilityMode.cacheOnly,caps.beginAuthorization(scope.capture()!)!),true);
  allow();
  final store=Store(scope); final resolver=ScopedForwardFileResolver(store:store,capabilities:caps);
  ChatFile file({String id='file',String url='url',String chat='source',String message='message',bool verified=true,bool deleted=false}) => ChatFile(id:id, chatId:chat,messageId:message,fileName:'file.pdf',fileKey:'key',fileUrl:url,fileType:'application/pdf',fileSize:1,uploadedBy:'a',uploadedAt:DateTime.utc(2026),isDeleted:deleted,deletionVerified:verified);
  Message row(List<ChatFile> fs) => Message(id:'message',chatId:'source',authorId:'a',authorLogin:'a',authorName:'a',text:'',at:DateTime.utc(2026),attachments:fs);
  Future<ScopedForwardFile?> lookup() => resolver.resolve(chatId:'source',messageId:'message',fileId:'file',url:'url');
  store.rows=[row([file()])]; final hit=await lookup(); expect(hit?.isCurrent,true);
  store.rows=[row([file(verified:false)])]; expect(await lookup(),isNull);
  store.rows=[row([file(deleted:true)])]; expect(await lookup(),isNull);
  store.rows=[row([file(),file()])]; expect(await lookup(),isNull);
  store.rows=[row([file()]),row([file()])]; expect(await lookup(),isNull);
  store.rows=[row([file(url:'other')])]; expect(await lookup(),isNull);
  store.rows=[row([file(chat:'other')])]; expect(await lookup(),isNull);
  store.rows=[row([file(message:'other')])]; expect(await lookup(),isNull);
  store.gate=Completer<List<Message>?>(); final pending=lookup();
  session=fakeSession('b'); events.add(AuthState(AuthChangeEvent.signedIn,session));
  session=fakeSession('a'); events.add(AuthState(AuthChangeEvent.signedIn,session)); allow();
  store.gate!.complete([row([file()])]); expect(await pending,isNull); expect(hit!.isCurrent,false);
  store.gate=Completer<List<Message>?>(); final revoked=lookup(); caps.block(); store.gate!.complete([row([file()])]); expect(await revoked,isNull);
  caps.dispose(); scope.dispose(); await events.close();
 });
}
