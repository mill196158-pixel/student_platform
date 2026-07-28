import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/common/keyboard_dismiss_scope.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_plus_menu.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_composer_capabilities.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/schedule/models/schedule_group_action_mapper.dart';

void main() {
  group('Stage 13.10 composer matrix', () {
    test('topic only in active subject chats', () {
      expect(
        ChatComposerCapabilities.showTopicForKind(
          isDm: false,
          teamKind: 'subject',
        ),
        isTrue,
      );
      expect(
        ChatComposerCapabilities.showTopicForKind(
          isDm: false,
          teamKind: 'group_space',
        ),
        isFalse,
      );
      expect(
        ChatComposerCapabilities.showTopicForKind(
          isDm: true,
          teamKind: 'dm',
        ),
        isFalse,
      );
    });

    test('collection only in group_space', () {
      expect(
        ChatComposerCapabilities.showCollectionForKind(
          isDm: false,
          teamKind: 'group_space',
        ),
        isTrue,
      );
      expect(
        ChatComposerCapabilities.showCollectionForKind(
          isDm: false,
          teamKind: 'subject',
        ),
        isFalse,
      );
      expect(
        ChatComposerCapabilities.showCollectionForKind(
          isDm: true,
          teamKind: 'dm',
        ),
        isFalse,
      );
    });

    test('DM shows none of group actions / propose', () {
      expect(ChatComposerCapabilities.showProposeForKind(isDm: true), isFalse);
      expect(
        ChatComposerCapabilities.showTopicForKind(isDm: true, teamKind: 'dm'),
        isFalse,
      );
      expect(
        ChatComposerCapabilities.showCollectionForKind(
          isDm: true,
          teamKind: 'dm',
        ),
        isFalse,
      );
    });

    test('menu actions do not disappear after structural publish state', () {
      // Structural visibility is independent of card count / published entity.
      final before = ChatComposerCapabilities.structuralLoading(
        teamKind: 'subject',
        isDm: false,
      );
      final afterPublish = before.copyWith(
        loading: false,
        canProposeAssignment: true,
        canCreateTopicSelection: true,
      );
      expect(afterPublish.showProposeAssignment, isTrue);
      expect(afterPublish.showTopicSelection, isTrue);
      expect(afterPublish.showCollection, isFalse);
      expect(afterPublish.canProposeAssignment, isTrue);
      expect(afterPublish.canCreateTopicSelection, isTrue);
    });

    test('ordinary assignment action remains for group_space and subject', () {
      expect(
        ChatComposerCapabilities.showProposeForKind(isDm: false),
        isTrue,
      );
      final group = ChatComposerCapabilities.structuralLoading(
        teamKind: 'group_space',
        isDm: false,
      );
      expect(group.showProposeAssignment, isTrue);
      expect(group.showTopicSelection, isFalse);
      expect(group.showCollection, isTrue);
    });

    testWidgets('plus menu keeps disabled tiles while loading', (tester) async {
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
              showProposeInPlus: true,
              showTopicSelectionInPlus: true,
              showCollectionInPlus: false,
              capabilitiesLoading: true,
              proposeEnabled: false,
              topicSelectionEnabled: false,
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester
          .pump(); // sheet open; avoid settle (loading spinner animates)
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Новое задание'), findsOneWidget);
      expect(find.text('Выбор темы'), findsOneWidget);
      expect(find.text('Скинуться'), findsNothing);
      expect(find.text('Проверяем права…'), findsWidgets);
    });

    testWidgets('Скинуться label used instead of Сбор', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPlusButton(
              actions: [
                ChatPlusAction(
                  icon: Icons.volunteer_activism_outlined,
                  title: 'Скинуться',
                  subtitle: 'Организация взноса',
                  onTap: () async {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('Скинуться'), findsOneWidget);
      expect(find.text('Сбор'), findsNothing);
    });
  });

  group('Stage 13.10 schedule presentation', () {
    test('uses real title and neutral badge, no technical words', () {
      final events = mapScheduleGroupActionEvents([
        GroupActionDeadline.fromJson({
          'event_type': 'topic_deadline',
          'entity_id': 's1',
          'title': 'Выбрать тему доклада',
          'occurs_at': '2026-08-01T12:00:00Z',
          'status': 'open',
        }),
        GroupActionDeadline.fromJson({
          'event_type': 'collection_deadline',
          'entity_id': 'c1',
          'title': 'Скинуться на подарок преподавателю',
          'occurs_at': '2026-08-02T12:00:00Z',
          'status': 'weird_raw_status',
        }),
      ]);
      expect(events[0].title, 'Выбрать тему доклада');
      expect(events[0].neutralBadge, isEmpty);
      expect(events[1].title, 'Скинуться на подарок преподавателю');
      expect(events[1].neutralBadge, isEmpty);
      expect(events[1].statusLabel, 'Открыто');
      for (final e in events) {
        expect(e.neutralBadge.toLowerCase().contains('topic'), isFalse);
        expect(e.neutralBadge.toLowerCase().contains('collection'), isFalse);
        expect(e.title.contains('topic_selection'), isFalse);
        expect(e.neutralBadge, isNot(equals('Выбор темы')));
        expect(e.neutralBadge, isNot(equals('Сбор')));
        expect(e.neutralBadge, isNot(equals('Задание по предмету')));
        expect(e.neutralBadge, isNot(equals('Задание группы')));
      }
    });

    test('canonical deadline coalesce in ChatTopicSelection', () {
      final s = ChatTopicSelection.fromJson({
        'id': '1',
        'title': 'T',
        'description': '',
        'status': 'open',
        'allow_change': true,
        'show_results_to_all': true,
        'completion_deadline_at': '2026-09-01T10:00:00Z',
      });
      expect(s.deadlineAt, isNotNull);
      expect(
          s.deadlineAt!.toUtc().toIso8601String(), '2026-09-01T10:00:00.000Z');
    });
  });

  group('Stage 13.10 keyboard dismiss', () {
    testWidgets('tap outside unfocuses', (tester) async {
      final focus = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardDismissScope(
              child: Column(
                children: [
                  TextField(focusNode: focus),
                  const SizedBox(height: 80, child: Text('outside')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.tap(find.text('outside'));
      await tester.pump();
      expect(focus.hasFocus, isFalse);
    });
  });

  group('Stage 13.10 group chat tile kinds', () {
    test('group_space team flagged', () {
      const groupTeam = Team(
        id: 't2',
        name: 'Чат группы',
        teacher: '',
        groupCode: '1-См',
        icon: 'groups',
        kind: 'group_space',
      );
      expect(groupTeam.isGroupSpaceChat, isTrue);
    });
  });
}
