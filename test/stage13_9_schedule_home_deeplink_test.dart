import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/data/personal_diary_service.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'package:student_platform/src/ui/schedule/models/schedule_group_action_mapper.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('PersonalDiaryData holds group action deadlines', () {
    const ctx = AcademicContext(hasActiveEnrollment: false);
    final occursAt = DateTime.utc(2026, 8, 1, 12);
    final data = PersonalDiaryData(
      academicContext: ctx,
      availableSemesters: const [],
      selectedSemesterNumber: null,
      allSubjects: const [],
      subjects: const [],
      latestEntries: const [],
      groupActions: [
        PersonalDiaryGroupAction(
          eventType: 'topic_deadline',
          entityId: 'sel-1',
          title: 'Доклад',
          occursAt: occursAt,
          myPickText: 'SQL и транзакции',
          teamName: 'Математика',
        ),
        PersonalDiaryGroupAction(
          eventType: 'collection_deadline',
          entityId: 'col-1',
          title: 'Сбор на пиццу',
          occursAt: occursAt.add(const Duration(days: 1)),
          myPickText: 'Отметил перевод',
        ),
      ],
      totalEntries: 0,
      totalFiles: 0,
    );

    expect(data.groupActions, hasLength(2));
    expect(data.groupActions.first.isTopic, isTrue);
    expect(data.groupActions.first.isCompleted, isFalse);
    expect(data.groupActions.first.displayTitle, 'Подготовить «SQL и транзакции»');
    expect(data.groupActions.last.isCollection, isTrue);
    expect(data.groupActions.last.isCompleted, isTrue);
  });

  test('mapScheduleGroupActionEvents dedupes by type entity occurs_at', () {
    final first = GroupActionDeadline.fromJson({
      'event_type': 'topic_deadline',
      'entity_id': 's1',
      'title': 'Темы',
      'occurs_at': '2026-08-01T12:00:00Z',
    });
    final duplicate = GroupActionDeadline.fromJson({
      'event_type': 'topic_deadline',
      'entity_id': 's1',
      'title': 'Темы (dup)',
      'occurs_at': '2026-08-01T12:00:00Z',
    });
    final other = GroupActionDeadline.fromJson({
      'event_type': 'collection_deadline',
      'entity_id': 'c1',
      'title': 'Сбор',
      'occurs_at': '2026-08-02T12:00:00Z',
    });

    final mapped = mapScheduleGroupActionEvents([first, duplicate, other]);
    expect(mapped, hasLength(2));
    expect(mapped.first.title, 'Темы');
    expect(mapped.last.isCollection, isTrue);
  });

  test('GroupActionDeeplinkArgs equality and fromDeadline factory', () {
    const a = GroupActionDeeplinkArgs(
      chatId: 'chat-1',
      cardMessageId: 'msg-1',
      entityType: 'topic_deadline',
      entityId: 'sel-1',
      teamId: 'team-1',
    );
    const b = GroupActionDeeplinkArgs(
      chatId: 'chat-1',
      cardMessageId: 'msg-1',
      entityType: 'topic_deadline',
      entityId: 'sel-1',
      teamId: 'team-1',
    );
    expect(a, equals(b));

    final fromFactory = GroupActionDeeplinkArgs.fromDeadline(
      eventType: 'collection_deadline',
      entityId: 'col-1',
      chatId: 'chat-2',
      cardMessageId: 'msg-2',
      teamId: 'team-2',
    );
    expect(fromFactory.entityType, 'collection_deadline');
    expect(fromFactory.entityId, 'col-1');
  });

  testWidgets('home summary shows group action pick text', (tester) async {
    final data = StudentHomeData(
      profile: const StudentHomeProfile(
        name: 'Аня',
        groupName: '1-См',
      ),
      currentDate: DateTime(2026, 7, 27),
      lessons: const [],
      assignments: const [],
      news: const [],
      groupActions: const [
        StudentHomeGroupAction(
          id: 'topic_deadline|s1',
          title: 'Доклад',
          kindLabel: 'Тема',
          deadlineText: '1 авг., 15:00',
          teamName: 'Математика',
          myPickText: 'SQL и транзакции',
          isTopic: true,
          followUpTitle: 'Подготовить «SQL и транзакции»',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: StudentHomeView(data: data),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Подготовить «SQL и транзакции»'), findsOneWidget);
    expect(find.textContaining('Тема · список «Доклад»'), findsOneWidget);
  });

  test('HomeGroupActionPreview maps enriched deadline fields', () {
    final deadline = GroupActionDeadline.fromJson({
      'event_type': 'topic_deadline',
      'entity_id': 's1',
      'title': 'Темы',
      'occurs_at': '2026-08-01T12:00:00Z',
      'team_name': 'Физика',
      'status': 'open',
      'my_pick_text': 'Лазеры',
    });
    final preview = HomeGroupActionPreview(
      eventType: deadline.eventType,
      entityId: deadline.entityId,
      title: deadline.title,
      occursAt: deadline.occursAt,
      teamName: deadline.teamName,
      status: deadline.status,
      myPickText: deadline.myPickText,
    );
    expect(preview.myPickText, 'Лазеры');
    expect(preview.teamName, 'Физика');
  });

  test('PushPayload accepts Stage 13.9 group action types and safe ids', () {
    for (final type in const [
      'topic_selection_created',
      'topic_deadline_soon',
      'topic_reassigned',
      'topic_pick_changed',
      'collection_created',
      'collection_deadline_soon',
      'collection_contribution_private',
    ]) {
      expect(PushPayload.knownTypes.contains(type), isTrue);
      final payload = PushPayload.tryParse({
        'version': '1',
        'type': type,
        'notification_id': 'n1',
        'chat_id': 'c1',
        'team_id': 't1',
        'selection_id': 's1',
        'collection_id': 'col1',
        'card_message_id': 'm1',
      });
      expect(payload, isNotNull);
      expect(payload!.isKnownType, isTrue);
      expect(payload.cardMessageId, 'm1');
      expect(payload.selectionId, 's1');
      expect(payload.collectionId, 'col1');
    }

    final unknown = PushPayload.tryParse({'type': 'evil_route', 'path': '/x'});
    expect(unknown, isNotNull);
    expect(unknown!.isKnownType, isFalse);
  });
}
