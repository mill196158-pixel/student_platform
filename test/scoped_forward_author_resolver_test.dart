import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/scoped_forward_author_resolver.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Store implements ProjectChatServerCache {
  _Store(this.scope);
  @override
  final AuthSessionScope scope;
  List<Message>? rows;
  Completer<List<Message>?>? gate;
  int calls = 0;
  @override
  Future<List<Message>?> read(
      String chat, SessionCapabilities capabilities) async {
    calls++;
    return gate == null ? rows : gate!.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test(
      'exact scoped author lookup rejects ambiguity, stale sessions and revoke',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    void allow() => expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    allow();
    final store = _Store(scope);
    final resolver =
        ScopedForwardAuthorResolver(store: store, capabilities: caps);
    Message row(
            {String id = 'message',
            String author = 'author',
            bool? verified = true}) =>
        Message(
            id: id,
            chatId: 'source',
            authorId: author,
            authorLogin: '',
            authorName: 'Name',
            authorNameVerified: verified,
            text: 'Студент',
            at: DateTime.utc(2026));
    Future<ScopedForwardAuthor?> resolve({String author = 'author'}) =>
        resolver.resolve(
            sourceChatId: 'source', messageId: 'message', authorId: author);
    store.rows = [row()];
    final hit = await resolve();
    expect(hit?.name, 'Name');
    expect(hit?.isCurrent, true);
    expect(await resolve(author: 'forged'), isNull);
    store.rows = [row(), row()];
    expect(await resolve(), isNull);
    store.rows = [row(verified: false)];
    expect(await resolve(), isNull);
    store.rows = [];
    expect(await resolve(), isNull);
    store.gate = Completer<List<Message>?>();
    final delayed = resolve();
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    allow();
    store.gate!.complete([row()]);
    expect(await delayed, isNull);
    expect(hit!.isCurrent, false);
    store.gate = Completer<List<Message>?>();
    final revoked = resolve();
    caps.block();
    store.gate!.complete([row()]);
    expect(await revoked, isNull);
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
