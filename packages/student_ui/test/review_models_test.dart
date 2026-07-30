import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('StudentReviewCard renders moderation badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentReviewCard(
            payload: StudentReviewCardPayload.demoPending,
            showDemoBadge: true,
          ),
        ),
      ),
    );
    expect(find.text('Пример'), findsOneWidget);
    expect(find.text('На модерации'), findsOneWidget);
    expect(find.text('Математический анализ'), findsOneWidget);
  });

  test('EntityReviewSummary parses get_entity_review_summary', () {
    final summary = EntityReviewSummary.tryParse({
      'entity_type': 'teacher',
      'entity_id': '11111111-1111-1111-1111-111111111111',
      'active_count': 3,
      'tag_averages': {'clarity': 4.5},
      'text_enabled': false,
      'structured_enabled': true,
    });
    expect(summary, isNotNull);
    expect(summary!.entityType, ReviewEntityType.teacher);
    expect(summary.activeCount, 3);
    expect(summary.tagAverages['clarity'], 4.5);
  });

  test('StudentPointsSummary parses get_my_points_summary', () {
    final summary = StudentPointsSummary.tryParse({
      'user_id': 'user-1',
      'balance': 2,
      'entries': [
        {
          'delta': 1,
          'reason_code': 'review_approved',
          'created_at': '2026-07-29T12:00:00Z',
        },
        {
          'delta': -1,
          'reason_code': 'review_credit_revoked',
        },
      ],
    });
    expect(summary, isNotNull);
    expect(summary!.balance, 2);
    expect(summary.entries.length, 2);
    expect(summary.entries.first.signedLabel, '+1');
    expect(
      summary.entries.last.reasonCode,
      PointsReasonCode.reviewCreditRevoked,
    );
  });

  test('UnifiedModerationQueueItem parses admin queue row', () {
    final item = UnifiedModerationQueueItem.tryParse({
      'domain': 'content_correction',
      'entity_id': '22222222-2222-2222-2222-222222222222',
      'parent_id': '33333333-3333-3333-3333-333333333333',
      'title': 'Справочник: расписание',
      'detail': 'Неверная ссылка на PDF',
      'status': 'open',
      'updated_at': '2026-07-29T10:00:00Z',
    });
    expect(item, isNotNull);
    expect(item!.domain, ModerationQueueDomain.contentCorrection);
    expect(item.title, 'Справочник: расписание');
  });

  test('MyEntityReviewItem parses moderation_reason', () {
    final item = MyEntityReviewItem.tryParse({
      'review_id': 'r-1',
      'entity_type': 'teacher',
      'entity_id': '11111111-1111-1111-1111-111111111111',
      'entity_label': 'Иванова А.А.',
      'tag_scores': {'clarity': 3},
      'moderation_status': 'rejected',
      'moderation_reason': 'Добавьте конкретику',
    });
    expect(item, isNotNull);
    expect(item!.moderationReason, 'Добавьте конкретику');
    expect(item.toCardPayload().moderationReason, 'Добавьте конкретику');
  });

  test('fail-closed parsers reject bad wire values', () {
    expect(
      EntityReviewSummary.tryParse({
        'entity_type': 'vacancy',
        'entity_id': '1',
      }),
      isNull,
    );
    expect(
      UnifiedModerationQueueItem.tryParse({
        'domain': 'unknown',
        'entity_id': '1',
        'title': 'x',
        'status': 'open',
      }),
      isNull,
    );
  });

  testWidgets('StudentPointsSummaryChip shows balance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentPointsSummaryChip(
            summary: StudentPointsSummary.demo,
            showDemoBadge: true,
          ),
        ),
      ),
    );
    expect(find.text('2 балл.'), findsOneWidget);
    expect(find.text('Пример'), findsOneWidget);
  });
}
