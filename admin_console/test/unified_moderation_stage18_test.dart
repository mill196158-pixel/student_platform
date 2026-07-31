import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/features/moderation/moderation_repository.dart';
import 'package:student_platform_admin/features/moderation/moderation_screen.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  AdminSessionController _localSession() {
    final session = AdminSessionController();
    session.phase = AdminSessionPhase.localPrototype;
    return session;
  }

  testWidgets('unified moderation tab lists local domains', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 900,
            width: 800,
            child: ModerationScreen(
              session: _localSession(),
              repository: LocalModerationRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Единая очередь'), findsOneWidget);
    expect(find.text('Отзыв · teacher'), findsOneWidget);
    expect(find.textContaining('Стажировка в IT'), findsOneWidget);

    final list = find.byType(ListView);
    for (var i = 0; i < 4; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('Жалоба на вакансию'), findsWidgets);
    expect(find.textContaining('Справочник: расписание'), findsOneWidget);
  });

  test('LocalModerationRepository filters unified queue by domain', () async {
    final repo = LocalModerationRepository();
    final reviews = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.review],
      status: 'open',
    );
    expect(reviews, isNotEmpty);
    expect(reviews.every((e) => e.domain == ModerationQueueDomain.review), isTrue);

    final corrections = await repo.listContentCorrections(status: 'open');
    expect(corrections, isNotEmpty);
    expect(corrections.first.contentTitle, contains('Справочник'));
  });

  test('LocalModerationRepository filters by author and priority', () async {
    final repo = LocalModerationRepository();
    final byAuthor = await repo.listUnifiedQueue(authorUserId: 'author-1');
    expect(byAuthor, hasLength(1));
    expect(byAuthor.first.authorLabel, 'Студент А.');

    final highPriority = await repo.listUnifiedQueue(minPriority: 20);
    expect(highPriority.every((e) => (e.priority ?? 0) >= 20), isTrue);
  });

  test('LocalModerationRepository applies unified review approve', () async {
    final repo = LocalModerationRepository();
    final before = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.review],
    );
    expect(before.first.status, ReviewModerationStatus.pending.wireValue);

    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.review,
      entityId: before.first.entityId,
      action: 'approve',
      reason: 'Соответствует правилам',
    );

    final after = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.review],
      status: 'all',
    );
    expect(after.first.status, ReviewModerationStatus.approved.wireValue);
  });

  test('LocalModerationRepository resolves vacancy report', () async {
    final repo = LocalModerationRepository();
    final before = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancyReport],
    );
    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.vacancyReport,
      entityId: before.first.entityId,
      action: 'resolve',
      reason: 'Подтверждено',
    );
    final after = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancyReport],
      status: 'closed',
    );
    expect(after.first.status, 'resolved');
  });

  test('LocalModerationRepository exposes review history', () async {
    final repo = LocalModerationRepository();
    final history = await repo.listReviewHistory(reviewId: 'local-review-1');
    expect(history, isNotEmpty);
    expect(history.first.action, 'approve');
  });

  test('legacy review queue hide updates status', () async {
    final repo = LocalModerationRepository();
    final items = await repo.listLegacyReviewQueue();
    await repo.moderateLegacyReview(
      reviewId: items.first.reviewId,
      action: 'hide',
      reason: 'Спам',
    );
    final after = await repo.listLegacyReviewQueue();
    expect(after.first.status, 'hidden');
  });

  test('LocalModerationRepository take_in_moderation before approve', () async {
    final repo = LocalModerationRepository();
    final before = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancy],
    );
    expect(before.first.status, 'submitted');

    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.vacancy,
      entityId: before.first.entityId,
      action: 'take_in_moderation',
      reason: '',
      expectedRowVersion: before.first.rowVersion,
    );

    final inModeration = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancy],
      status: 'all',
    );
    expect(inModeration.first.status, 'in_moderation');

    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.vacancy,
      entityId: before.first.entityId,
      action: 'approve',
      reason: 'OK',
      expectedRowVersion: inModeration.first.rowVersion,
    );

    final approved = await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancy],
      status: 'all',
    );
    expect(approved.first.status, 'approved');
  });

  test('LocalModerationRepository request_clarification returns vacancy to draft',
      () async {
    final repo = LocalModerationRepository();
    final item = (await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancy],
    ))
        .first;

    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.vacancy,
      entityId: item.entityId,
      action: 'take_in_moderation',
      reason: '',
      expectedRowVersion: item.rowVersion,
    );

    final inModeration = (await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancy],
      status: 'all',
    ))
        .first;

    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.vacancy,
      entityId: item.entityId,
      action: 'request_clarification',
      reason: 'Нужен контакт HR',
      expectedRowVersion: inModeration.rowVersion,
    );

    final draft = (await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.vacancy],
      status: 'all',
    ))
        .first;
    expect(draft.status, 'draft');
  });

  test('LocalModerationRepository request_clarification on review', () async {
    final repo = LocalModerationRepository();
    final item = (await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.review],
    ))
        .first;

    await repo.applyUnifiedAction(
      domain: ModerationQueueDomain.review,
      entityId: item.entityId,
      action: 'request_clarification',
      reason: 'Уточните формулировку',
    );

    final after = (await repo.listUnifiedQueue(
      domains: const [ModerationQueueDomain.review],
      status: 'all',
    ))
        .first;
    expect(after.status, ReviewModerationStatus.rejected.wireValue);
  });

  testWidgets('moderation.action capability enables Решить button', (tester) async {
    final session = AdminSessionController();
    session.phase = AdminSessionPhase.ready;
    session.capabilities = const AdminCapabilities(
      userId: 'mod-1',
      permissions: {'moderation.action'},
      assignments: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 900,
            width: 800,
            child: ModerationScreen(
              session: session,
              repository: LocalModerationRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Решить'), findsWidgets);
  });

  testWidgets('submitted vacancy dialog offers take_in_moderation not approve',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 900,
            width: 800,
            child: ModerationScreen(
              session: _localSession(),
              repository: LocalModerationRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final vacancyRow = find.ancestor(
      of: find.textContaining('Стажировка в IT'),
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(vacancyRow);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: vacancyRow,
        matching: find.widgetWithText(FilledButton, 'Решить'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Взять в работу'), findsOneWidget);
    expect(find.text('Одобрить'), findsNothing);
    expect(find.text('Запросить уточнение'), findsOneWidget);
  });
}
