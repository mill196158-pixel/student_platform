import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/widgets/offline_assignment_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/assignment_bubble.dart';
import 'auth_session_scope_test.dart' show fakeSession;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_message_bubble.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/file_message_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';

class _Service implements DmChatService {
  @override String get currentUserId => 'owner';
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('saved image uses file layout and read-only online reaction chip', (tester) async {
    await initializeDateFormatting('ru');
    final now = DateTime(2026, 6, 21, 9, 20);
    final file = ChatFile(id: 'image', chatId: 'chat', messageId: 'message',
      fileName: 'image.png', fileKey: 'image', fileType: 'image/png', fileSize: 8,
      fileUrl: 'https://example.invalid/image', uploadedBy: 'owner', uploadedAt: now);
    final message = Message(id: 'message', chatId: 'chat', authorId: 'owner',
      authorLogin: '', authorName: 'Owner', text: '', at: now, attachments: [file],
      reactions: const {'❤️': 1}, userReactions: const ['❤️']);
    var mutations = 0;
    final controller = ScrollController();
    final search = ChatSearchController();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatMessageList(
      messages: [message], controller: controller, messageKeys: {}, search: search,
      currentUserId: 'owner', showEntryNewBadge: false, forceHideAvatars: true,
      noAvatarSpacing: true, hideAuthorLine: true, selectingMessages: false,
      selectedMessageIds: const {}, onToggleSelect: null,
      onReply: (_) => mutations++, onReplyTap: (_) => mutations++,
      onLongPress: (_, __, ___, ____, _____, ______) => mutations++,
      onReact: (_, __) => mutations++,
      localOnlyBubbleBuilder: (m) => CachedChatMessageBubble(message: m,
        service: _Service(), showAuthor: false,
        debugForwardAttachmentBuilder: (_) => const SizedBox(width: 220, height: 220,
          child: Text('LOCAL IMAGE'))),
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(FileMessageBubble), findsOneWidget);
    expect(find.text('LOCAL IMAGE'), findsOneWidget);
    expect(find.text('❤️'), findsOneWidget);
    expect(find.text('❤️ 1'), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is Image && widget.image is NetworkImage), findsNothing);
    await tester.tap(find.text('❤️'), warnIfMissed: false);
    await tester.longPress(find.text('LOCAL IMAGE'));
    await tester.pumpAndSettle();
    expect(mutations, 0);
    expect(tester.state<NavigatorState>(find.byType(Navigator)).canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose(); search.dispose();
  });
  testWidgets('saved assignment shares online card without network actions and hides on owner change', (tester) async {
    var session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!), isTrue);
    final permit = caps.capture(SessionCapability.cachedRead)!;
    final at = DateTime(2026, 6, 20, 10);
    final assignment = Assignment(id: 'task', title: 'Билеты', description: 'Описание',
      published: false, votes: 0, completedByMe: false, createdBy: 'owner', createdAt: at,
      attachments: const [{'name': 'photo.png', 'path': 'https://example.invalid/photo.png'}]);
    final message = Message(id: 'm', chatId: 'chat', authorId: 'owner', authorLogin: '',
      authorName: 'Owner', text: '', at: at, assignmentId: 'task', type: MessageType.assignmentDraft);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OfflineAssignmentBubble(
      message: message, assignment: assignment, capabilities: caps, permit: permit))));
    expect(find.byType(AssignmentBubble), findsOneWidget);
    expect(find.text('Билеты'), findsOneWidget);
    expect(find.text('Открыть'), findsOneWidget);
    expect(find.text('Редактировать'), findsNothing);
    expect(find.text('Голосовать'), findsNothing);
    expect(find.text('Опубликовать'), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is Image && widget.image is NetworkImage), findsNothing);
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.textContaining('сохранённая копия'), findsOneWidget);
    session = fakeSession('different-owner');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(find.text('Сохранённое задание недоступно.'), findsOneWidget);
    expect(find.text('Описание'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose(); scope.dispose(); await events.close();
  });

}
