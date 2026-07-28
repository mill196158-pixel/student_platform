import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/common/friendly_empty_state.dart';
import 'package:student_platform/src/ui/common/keyboard_dismiss_scope.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_composer_capabilities.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/schedule/models/schedule_group_action_mapper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 13.11 permissions matrix', () {
    test('subject member creates topic without organizer', () {
      final caps = ChatComposerCapabilities.fromJson({
        'chat_type': 'team',
        'team_kind': 'subject',
        'is_active_member': true,
        'is_active_subject_team': true,
        'show_propose_assignment': true,
        'show_topic_selection': true,
        'show_collection': false,
        'can_propose_assignment': true,
        'can_manage_assignments': false,
        'can_create_assignment': true,
        'can_create_topic_selection': true,
        'can_create_collection': false,
        'can_edit_own_before_activity': true,
        'can_moderate_topic_selection': false,
        'can_moderate_collection': false,
        'can_manage_collection_receipts': false,
        'can_delete_group_action': false,
      });
      expect(caps.canCreateTopicSelection, isTrue);
      expect(caps.canModerateTopicSelection, isFalse);
      expect(caps.canCreateCollection, isFalse);
    });

    test('group_space member creates collection without organizer', () {
      final caps = ChatComposerCapabilities.fromJson({
        'chat_type': 'team',
        'team_kind': 'group_space',
        'is_active_member': true,
        'is_active_subject_team': false,
        'show_propose_assignment': true,
        'show_topic_selection': false,
        'show_collection': true,
        'can_propose_assignment': true,
        'can_manage_assignments': false,
        'can_create_assignment': true,
        'can_create_topic_selection': false,
        'can_create_collection': true,
        'can_edit_own_before_activity': true,
        'can_moderate_topic_selection': false,
        'can_moderate_collection': false,
        'can_manage_collection_receipts': false,
        'can_delete_group_action': false,
      });
      expect(caps.canCreateCollection, isTrue);
      expect(caps.canCreateTopicSelection, isFalse);
      expect(caps.canDeleteGroupAction, isFalse);
    });

    test('DM forbids assignment/topic/collection creation', () {
      final caps = ChatComposerCapabilities.fromJson({
        'chat_type': 'dm',
        'team_kind': 'dm',
        'is_active_member': false,
        'is_active_subject_team': false,
        'show_propose_assignment': false,
        'show_topic_selection': false,
        'show_collection': false,
        'can_propose_assignment': false,
        'can_manage_assignments': false,
        'can_create_assignment': false,
        'can_create_topic_selection': false,
        'can_create_collection': false,
        'can_edit_own_before_activity': false,
        'can_moderate_topic_selection': false,
        'can_moderate_collection': false,
        'can_manage_collection_receipts': false,
        'can_delete_group_action': false,
      });
      expect(caps.showProposeAssignment, isFalse);
      expect(caps.canCreateTopicSelection, isFalse);
      expect(caps.canCreateCollection, isFalse);
    });

    test('organizer gets moderation/delete flags separately from create', () {
      final caps = ChatComposerCapabilities.fromJson({
        'chat_type': 'team',
        'team_kind': 'subject',
        'is_active_member': true,
        'is_active_subject_team': true,
        'show_propose_assignment': true,
        'show_topic_selection': true,
        'show_collection': false,
        'can_propose_assignment': true,
        'can_manage_assignments': true,
        'can_create_assignment': true,
        'can_create_topic_selection': true,
        'can_create_collection': false,
        'can_edit_own_before_activity': true,
        'can_moderate_topic_selection': true,
        'can_moderate_collection': false,
        'can_manage_collection_receipts': false,
        'can_delete_group_action': true,
      });
      expect(caps.canCreateTopicSelection, isTrue);
      expect(caps.canModerateTopicSelection, isTrue);
      expect(caps.canDeleteGroupAction, isTrue);
    });

    test('account 24002820 subject member matrix after fix', () {
      // Ordinary subject member (not organizer) — creation allowed.
      final caps = ChatComposerCapabilities.fromJson({
        'chat_type': 'team',
        'team_kind': 'subject',
        'is_active_member': true,
        'is_active_subject_team': true,
        'show_propose_assignment': true,
        'show_topic_selection': true,
        'show_collection': false,
        'can_propose_assignment': true,
        'can_manage_assignments': false,
        'can_create_assignment': true,
        'can_create_topic_selection': true,
        'can_create_collection': false,
        'can_edit_own_before_activity': true,
        'can_moderate_topic_selection': false,
        'can_moderate_collection': false,
        'can_manage_collection_receipts': false,
        'can_delete_group_action': false,
        'reasons': {
          'topic_selection': null,
          'collection': 'subject_not_allowed',
        },
      });
      expect(caps.canCreateTopicSelection, isTrue);
      expect(caps.reasonLabel('topic_selection'), isNot(contains('организатор')));
      expect(caps.reasonLabel('topic_selection'), isNot(contains('Проверяем')));
    });

    test('reasonLabel never shows Проверяем права', () {
      final loading = ChatComposerCapabilities.structuralLoading(
        teamKind: 'subject',
        isDm: false,
      );
      expect(loading.reasonLabel('topic_selection'), isNot(contains('Проверяем')));
      expect(loading.reasonLabel('topic_selection'), isNot(contains('Определяем')));
    });
  });

  group('Stage 13.11 silent menu', () {
    testWidgets('no Проверяем права text; spinner only when unknown',
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Создать задание'), findsOneWidget);
      expect(find.text('Выбор темы'), findsOneWidget);
      expect(find.textContaining('Проверяем'), findsNothing);
      expect(find.textContaining('Определяем доступ'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    test('cached success survives structural loading overlay', () {
      final success = ChatComposerCapabilities.fromJson({
        'chat_type': 'team',
        'team_kind': 'subject',
        'is_active_member': true,
        'is_active_subject_team': true,
        'show_propose_assignment': true,
        'show_topic_selection': true,
        'show_collection': false,
        'can_propose_assignment': true,
        'can_manage_assignments': false,
        'can_create_assignment': true,
        'can_create_topic_selection': true,
        'can_create_collection': false,
        'can_edit_own_before_activity': true,
        'can_moderate_topic_selection': false,
        'can_moderate_collection': false,
        'can_manage_collection_receipts': false,
        'can_delete_group_action': false,
      });
      final afterTransient = success.copyWith(fromCache: true, loading: false);
      expect(afterTransient.canCreateTopicSelection, isTrue);
      expect(afterTransient.showTopicSelection, isTrue);
      // Multiple cards must not change structural matrix.
      expect(afterTransient.showProposeAssignment, isTrue);
    });

    test('reload/realtime do not hide subject topic action', () {
      final before = ChatComposerCapabilities.structuralLoading(
        teamKind: 'subject',
        isDm: false,
      );
      final afterRealtime = before.copyWith(
        loading: false,
        canProposeAssignment: true,
        canCreateAssignment: true,
        canCreateTopicSelection: true,
      );
      expect(afterRealtime.showTopicSelection, isTrue);
      expect(afterRealtime.canCreateTopicSelection, isTrue);
      expect(afterRealtime.showCollection, isFalse);
    });
  });

  group('Stage 13.11 unified schedule', () {
    test('three kinds share one assignment list presentation', () {
      final events = mapScheduleGroupActionEvents([
        GroupActionDeadline.fromJson({
          'event_type': 'topic_deadline',
          'entity_id': 's1',
          'title': 'Темы докладов по экологии',
          'occurs_at': '2026-08-01T12:00:00Z',
          'status': 'open',
          'card_message_id': 'msg-1',
        }),
        GroupActionDeadline.fromJson({
          'event_type': 'collection_deadline',
          'entity_id': 'c1',
          'title': 'Подарок преподавателю',
          'occurs_at': '2026-08-02T12:00:00Z',
          'status': 'open',
          'card_message_id': 'msg-2',
        }),
      ]);
      expect(events.length, 2);
      expect(events[0].title, 'Темы докладов по экологии');
      expect(events[1].title, 'Подарок преподавателю');
      for (final e in events) {
        expect(e.neutralBadge, isEmpty);
        expect(e.title.contains('topic_selection'), isFalse);
        expect(e.title.contains('group_collection'), isFalse);
        expect(e.cardMessageId, isNotNull);
      }
      // Sorted by deadline
      expect(events[0].occursAt.isBefore(events[1].occursAt), isTrue);
    });
  });

  group('Stage 13.11 empty state + lottie', () {
    testWidgets('FriendlyEmptyState readable in light and dark', (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness, useMaterial3: true),
            home: const Scaffold(
              body: FriendlyEmptyState(
                lottieAsset: 'assets/lottie/empty_assignments_fox.json',
                title: 'Заданий пока нет',
                subtitle: 'Создайте первое задание в чате.',
                fallbackIcon: Icons.assignment_outlined,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Заданий пока нет'), findsOneWidget);
        final text = tester.widget<Text>(find.text('Заданий пока нет'));
        final color = text.style?.color;
        expect(color, isNotNull);
        // Must not be pure white on unknown bg — ColorScheme driven.
        expect(color, isNot(equals(Colors.white)));
      }
    });

    testWidgets('reduce motion uses non-animating fallback path', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: const Scaffold(
              body: FriendlyEmptyState(
                lottieAsset: 'assets/lottie/empty_images_cat.json',
                title: 'Пока нет изображений',
                subtitle: 'Фото из чата появятся здесь.',
                fallbackIcon: Icons.photo_outlined,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Пока нет изображений'), findsOneWidget);
    });
  });

  group('Stage 13.11 keyboard', () {
    testWidgets('KeyboardDismissScope closes on outside tap', (tester) async {
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
}
