import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/immutable_message_snapshot.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  test('detaches all nested mutable collections without dropping delivery metadata', () {
    final files = <ChatFile>[
      ChatFile(id: 'file', chatId: 'chat', messageId: 'local', fileName: 'file.pdf',
        fileKey: 'key', fileUrl: 'url', fileType: 'application/pdf', fileSize: 2,
        uploadedBy: 'owner', uploadedAt: DateTime.utc(2026), deletionVerified: true),
    ];
    final reactions = <String, int>{'👍': 1};
    final mine = <String>['👍'];
    final outgoing = <String>['file'];
    final forwards = <ForwardAttachmentModel>[ForwardAttachmentModel(id: 'file', url: 'url')];
    final items = <ForwardItemModel>[ForwardItemModel(id: 'inner', authorId: 'owner',
        authorName: 'Name', at: DateTime.utc(2026), attachments: forwards)];
    final original = Message(id: 'local', clientId: 'local', chatId: 'chat',
      authorId: 'owner', authorLogin: 'login', authorName: 'Name', text: 'text',
      at: DateTime.utc(2026), deliveryStatus: MessageDeliveryStatus.failed,
      attachments: files, reactions: reactions, userReactions: mine,
      outboundFileIds: outgoing, forward: ForwardPayloadModel(fromChatId: 'source', items: items));

    final result = immutableMessageSnapshot([original]);
    expect(result.single.toJson(), original.toJson());
    expect(result.single.userReactions, original.userReactions);
    files.clear(); reactions.clear(); mine.clear(); outgoing.clear(); forwards.clear(); items.clear();
    final copy = result.single;
    expect(copy.attachments!.single.id, 'file');
    expect(copy.reactions, {'👍': 1});
    expect(copy.userReactions, ['👍']);
    expect(copy.outboundFileIds, ['file']);
    expect(copy.forward!.items.single.attachments.single.id, 'file');
    expect(copy.clientId, 'local');
    expect(copy.deliveryStatus, MessageDeliveryStatus.failed);
    expect(() => result.clear(), throwsUnsupportedError);
    expect(() => copy.attachments!.clear(), throwsUnsupportedError);
    expect(() => copy.reactions!.clear(), throwsUnsupportedError);
    expect(() => copy.userReactions!.clear(), throwsUnsupportedError);
    expect(() => copy.outboundFileIds.clear(), throwsUnsupportedError);
    expect(() => copy.forward!.items.clear(), throwsUnsupportedError);
    expect(() => copy.forward!.items.single.attachments.clear(), throwsUnsupportedError);
  });

  test('scope and capability revocation hide an already detached snapshot', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    var sourceCurrent = true;
    final snapshot = ScopedImmutableMessageSnapshot.capture(capabilities: capabilities,
        sourceCurrent: () => sourceCurrent, alreadyLoaded: []);
    expect(snapshot?.readable, isEmpty);
    sourceCurrent = false;
    expect(snapshot?.readable, isNull);
    sourceCurrent = true;
    expect(snapshot?.readable, isNull);
    final second = ScopedImmutableMessageSnapshot.capture(capabilities: capabilities,
        sourceCurrent: () => sourceCurrent, alreadyLoaded: []);
    expect(second?.readable, isEmpty);
    capabilities.block();
    expect(second?.readable, isNull);
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });

  test('account switch and switch back cannot revive an old snapshot', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final capabilities = SessionCapabilities(scope);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    final snapshot = ScopedImmutableMessageSnapshot.capture(capabilities: capabilities,
        sourceCurrent: () => true, alreadyLoaded: []);
    expect(snapshot?.readable, isEmpty);
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(snapshot?.readable, isNull);
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(snapshot?.readable, isNull);
    capabilities.dispose();
    scope.dispose();
    await events.close();
  });
}
