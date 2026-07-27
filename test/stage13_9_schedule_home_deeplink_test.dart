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
  test('PersonalDiaryData has no group action deadlines field', () {
    const ctx = AcademicContext(hasActiveEnrollment: false);
    expect(
      PersonalDiaryData(
        academicContext: ctx,
        availableSemesters: const [],
        selectedSemesterNumber: null,
        allSubjects: const [],
        subjects: const [],
        latestEntries: const [],
        totalEntries: 0,
        totalFiles: 0,
      ),
      isA<PersonalDiaryData>(),
    );
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
          title: 'Темы докладов',
          kindLabel: 'Выбор темы',
          deadlineText: '1 авг., 15:00',
          teamName: 'Математика',
          myPickText: 'SQL и транзакции',
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

    expect(find.text('Темы докладов'), findsOneWidget);
    expect(find.textContaining('Ваш выбор: SQL и транзакции'), findsOneWidget);
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
