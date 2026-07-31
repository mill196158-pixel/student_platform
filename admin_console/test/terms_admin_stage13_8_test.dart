import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/features/system/terms/terms_repository.dart';
import 'package:student_platform_admin/features/system/terms/terms_screen.dart';

class _TestSession extends AdminSessionController {
  _TestSession({
    required AdminSessionPhase initialPhase,
    AdminCapabilities capabilities = AdminCapabilities.empty,
  }) {
    phase = initialPhase;
    this.capabilities = capabilities;
  }
}

void main() {
  test('backfill does not change current and is idempotent', () async {
    final repo = LocalTermsRepository();
    final before = await repo.listTerms();
    final currentBefore = before.firstWhere((t) => t.isCurrent).id;

    final dry = await repo.backfillDryRun('t3');
    expect(dry['current_unchanged'], isTrue);
    expect(dry['chats_not_archived'], isTrue);
    expect(dry['missing_subjects'], greaterThan(0));

    final first = await repo.backfill('t3');
    expect(first['idempotent_replay'], isFalse);
    expect(first['current_unchanged'], isTrue);
    expect(first['chats_not_archived'], isTrue);

    final second = await repo.backfill('t3');
    expect(second['idempotent_replay'], isTrue);

    final after = await repo.listTerms();
    expect(after.firstWhere((t) => t.isCurrent).id, currentBefore);
  });

  test('past term cannot be activated; only nearest next', () async {
    final repo = LocalTermsRepository();
    final pastPreview = await repo.startNextDryRun('t1');
    expect(pastPreview.ok, isFalse);
    expect(pastPreview.blockers, isNotEmpty);

    expect(
      () => repo.startNext(termId: 't1', confirmName: 'осень 2025'),
      throwsStateError,
    );

    final nextPreview = await repo.startNextDryRun('t3');
    expect(nextPreview.ok, isTrue);
    expect(nextPreview.confirmNameRequired, 'осень 2026');

    final started = await repo.startNext(
      termId: 't3',
      confirmName: 'осень 2026',
    );
    expect(started['idempotent_replay'], isFalse);
    expect(started['group_space_preserved'], isTrue);

    final terms = await repo.listTerms();
    expect(terms.where((t) => t.isCurrent).length, 1);
    expect(terms.firstWhere((t) => t.isCurrent).id, 't3');
  });

  testWidgets('terms screen uses safe copy and start-next confirm', (
    tester,
  ) async {
    final session = _TestSession(
      initialPhase: AdminSessionPhase.ready,
      capabilities: const AdminCapabilities(
        userId: 'admin-1',
        permissions: {'dashboard.view', 'terms.manage'},
        assignments: [],
      ),
    );
    final repo = LocalTermsRepository();
    final view = tester.view;
    view.physicalSize = const Size(1200, 2000);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TermsScreen(session: session, repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Учебные периоды'), findsOneWidget);
    expect(find.text('Создать недостающее'), findsWidgets);
    expect(find.text('Проверить готовность'), findsWidgets);
    final startButton = find.widgetWithText(
      FilledButton,
      'Начать новый семестр',
    );
    expect(startButton, findsOneWidget);
    expect(find.textContaining('apply'), findsNothing);
    expect(find.textContaining('offerings'), findsNothing);
    expect(find.textContaining('teams'), findsNothing);

    await tester.ensureVisible(startButton);
    await tester.tap(startButton);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Постоянный чат учебной группы сохранится'),
      findsOneWidget,
    );
    expect(
      find.textContaining('архивировано предметных чатов'),
      findsOneWidget,
    );
    expect(find.text('Начать новый семестр'), findsWidgets);
  });
}
