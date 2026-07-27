import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/subject_difficulty.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_models.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_controller.dart';

void main() {
  testWidgets('Info strip has no group-space entry button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfoAcademicContextStrip(
            contextData: const AcademicContext(
              groupName: '1-См(ВВ)-2',
              recordBookNumber: '123',
              currentSemesterNumber: 2,
              hasActiveEnrollment: true,
            ),
            sessionDifficulty: const SessionDifficultySummary.empty(),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('open-group-space')), findsNothing);
    expect(find.textContaining('Пространство группы'), findsNothing);
  });

  testWidgets('DM-style composer hides topic and collection actions',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposerBar(
            controller: TextEditingController(),
            focusNode: FocusNode(),
            replyTo: null,
            onCloseReply: () {},
            someoneTyping: false,
            typingNames: const [],
            attachedFiles: const [],
            onSend: () {},
            onPickImage: () async {},
            onOpenEmoji: () {},
            onAttachFile: () async {},
            onRemoveFile: (_) {},
            onAddFile: (_) {},
            onPinText: (_) {},
            onFind: () async {},
            onPropose: (_, __, ___, ____, _____) async {},
            showTopicSelectionInPlus: false,
            showCollectionInPlus: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Выбор темы'), findsNothing);
    expect(find.text('Сбор'), findsNothing);
  });

  testWidgets('Group chat composer builds with topic flag enabled',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposerBar(
            controller: TextEditingController(),
            focusNode: FocusNode(),
            replyTo: null,
            onCloseReply: () {},
            someoneTyping: false,
            typingNames: const [],
            attachedFiles: const [],
            onSend: () {},
            onPickImage: () async {},
            onOpenEmoji: () {},
            onAttachFile: () async {},
            onRemoveFile: (_) {},
            onAddFile: (_) {},
            onPinText: (_) {},
            onFind: () async {},
            onPropose: (_, __, ___, ____, _____) async {},
            showTopicSelectionInPlus: true,
            showCollectionInPlus: false,
          ),
        ),
      ),
    );
    expect(find.byType(ChatComposerBar), findsOneWidget);
  });

  testWidgets('Group_space composer builds with collection flag enabled',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposerBar(
            controller: TextEditingController(),
            focusNode: FocusNode(),
            replyTo: null,
            onCloseReply: () {},
            someoneTyping: false,
            typingNames: const [],
            attachedFiles: const [],
            onSend: () {},
            onPickImage: () async {},
            onOpenEmoji: () {},
            onAttachFile: () async {},
            onRemoveFile: (_) {},
            onAddFile: (_) {},
            onPinText: (_) {},
            onFind: () async {},
            onPropose: (_, __, ___, ____, _____) async {},
            showTopicSelectionInPlus: true,
            showCollectionInPlus: true,
          ),
        ),
      ),
    );
    expect(find.byType(ChatComposerBar), findsOneWidget);
  });

  test('Plus menu visibility matrix for chat kinds', () {
    bool showTopic({required bool isDm, required bool canManage}) =>
        !isDm && canManage;
    bool showCollection({
      required bool isDm,
      required bool canManage,
      required String teamKind,
    }) =>
        !isDm && canManage && teamKind == 'group_space';

    expect(showTopic(isDm: true, canManage: true), isFalse);
    expect(showTopic(isDm: false, canManage: true), isTrue);
    expect(
      showCollection(isDm: false, canManage: true, teamKind: 'subject'),
      isFalse,
    );
    expect(
      showCollection(isDm: false, canManage: true, teamKind: 'group_space'),
      isTrue,
    );
  });

  test('Team kind flags group_space chat', () {
    const subjectTeam = Team(
      id: 't1',
      name: 'Математика',
      teacher: 'Иванов',
      groupCode: '1-См',
      icon: 'calc',
      kind: 'subject',
    );
    const groupTeam = Team(
      id: 't2',
      name: 'Чат группы',
      teacher: '',
      groupCode: '1-См',
      icon: 'groups',
      kind: 'group_space',
    );
    expect(subjectTeam.isGroupSpaceChat, isFalse);
    expect(groupTeam.isGroupSpaceChat, isTrue);
    expect(groupTeam.name, 'Чат группы');
    expect('${groupTeam.groupCode} · общий чат', '1-См · общий чат');
  });

  test('GroupActionDeadline maps RPC event types separately from assignments',
      () {
    final topic = GroupActionDeadline.fromJson({
      'event_type': 'topic_deadline',
      'entity_id': 's1',
      'title': 'Темы докладов',
      'occurs_at': '2026-08-01T12:00:00Z',
      'chat_id': 'c1',
      'payload': {'selection_id': 's1', 'card_message_id': 'm1'},
    });
    final collection = GroupActionDeadline.fromJson({
      'event_type': 'collection_deadline',
      'entity_id': 'col1',
      'title': 'На футболки',
      'occurs_at': '2026-08-02T12:00:00Z',
      'chat_id': 'c1',
      'payload': {'collection_id': 'col1'},
    });
    expect(topic.isTopic, isTrue);
    expect(topic.isCollection, isFalse);
    expect(collection.isCollection, isTrue);
    expect(collection.cardMessageId, isNull);
    expect(topic.cardMessageId, 'm1');
  });

  test('TopicDraft maps to publish json via controller', () {
    final controller = TopicListReviewController(
      initial: const [
        TopicDraft(title: 'Тема A', capacity: 2),
        TopicDraft(title: 'Тема B'),
      ],
    );

    final json = controller.toPublishJson();
    expect(json, hasLength(2));
    expect(json.first['title'], 'Тема A');
    expect(json.first['capacity'], 2);
    expect(json.first['sort_order'], 0);

    final options = publishJsonToOptionDrafts(json);
    expect(options.first.title, 'Тема A');
    expect(options.first.capacity, 2);
    expect(options.first.sortOrder, 1);
    expect(options.last.sortOrder, 2);
  });
}
