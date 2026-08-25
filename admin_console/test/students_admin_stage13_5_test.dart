import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/features/academic/students/group_space_organizer_dialog.dart';
import 'package:student_platform_admin/features/academic/students/group_space_organizer_models.dart';
import 'package:student_platform_admin/features/academic/students/students_repository.dart';
import 'package:student_platform_admin/features/academic/students/students_screen.dart';
import 'package:student_platform_admin/features/academic/teachers/teacher_import_service.dart';

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
  test('local students list/filter/block/assign', () async {
    final repo = LocalStudentsRepository();
    final active = await repo.listStudents(active: true);
    expect(active, isNotEmpty);
    await repo.updateStudent(id: active.first.id, isActive: false);
    final blocked = await repo.listStudents(active: false);
    expect(blocked.any((s) => s.id == active.first.id), isTrue);
    await repo.assignGroup(userId: active.first.id, groupId: 'g1');
  });

  test('student import dry-run requires existing login', () async {
    final workbook = Excel.createExcel();
    final sheet = workbook[workbook.getDefaultSheet()!];
    sheet.appendRow([
      TextCellValue('Логин'),
      TextCellValue('Имя'),
      TextCellValue('Фамилия'),
      TextCellValue('Группа'),
    ]);
    sheet.appendRow([
      TextCellValue('ivanov'),
      TextCellValue('Иван'),
      TextCellValue('Иванов'),
      TextCellValue('ИВТ-21'),
    ]);
    sheet.appendRow([
      TextCellValue('unknown_user'),
      TextCellValue('X'),
      TextCellValue('Y'),
      TextCellValue('ИВТ-21'),
    ]);
    final parsed = TeacherImportService().readFirstSheet(workbook.encode()!);
    final mapping = suggestStudentHeaderMapping(parsed.headers);
    final rows = [for (final raw in parsed.rows) mapImportRow(raw, mapping)];
    final repo = LocalStudentsRepository();
    final dry = await repo.importDryRun(rows);
    final items = dry['items'] as List;
    expect(items[0]['error_text'], 'academic_year_required');
    expect(items[1]['classification'], 'error');
    expect(items[1]['error_text'], 'auth_user_missing');
    final withYear = await repo.importDryRun(rows, academicYearId: 'y2026');
    final yearItems = withYear['items'] as List;
    expect(yearItems[0]['error_text'], 'group_name_shape_unrecognized');
    expect(yearItems[1]['error_text'], 'auth_user_missing');
    final profileOnly = await repo.importDryRun([
      {'login': 'ivanov', 'name': 'Иван', 'surname': 'Иванов'},
    ]);
    expect(profileOnly['items'][0]['classification'], 'update');
    final apply = await repo.importApply([
      {'login': 'ivanov', 'name': 'Иван', 'surname': 'Иванов'},
    ]);
    expect(apply['updated'], 1);
    final replay = await repo.importApply([
      {'login': 'ivanov', 'name': 'Иван', 'surname': 'Иванов'},
    ]);
    expect(replay['idempotent_replay'], isTrue);
  });

  test(
    'term backfill dry-run and idempotent apply without set_current',
    () async {
      final repo = LocalStudentsRepository();
      final dry = await repo.prepareTermDryRun('t2');
      expect(dry['missing_subjects'], greaterThan(0));
      expect(dry['current_unchanged'], isTrue);
      expect(
        () => repo.prepareTermApply(termId: 't2', setCurrent: true),
        throwsStateError,
      );
      final first = await repo.prepareTermApply(termId: 't2');
      expect(first['idempotent_replay'], isFalse);
      expect(first['set_current'], isFalse);
      final second = await repo.prepareTermApply(termId: 't2');
      expect(second['idempotent_replay'], isTrue);
    },
  );

  testWidgets('students screen has no dangerous term transition controls', (
    tester,
  ) async {
    final session = _TestSession(
      initialPhase: AdminSessionPhase.ready,
      capabilities: const AdminCapabilities(
        userId: 'admin-1',
        permissions: {
          'dashboard.view',
          'students.read',
          'students.write',
          'terms.manage',
        },
        assignments: [],
      ),
    );
    final repo = LocalStudentsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentsScreen(session: session, repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Студенты и группы'), findsOneWidget);
    expect(find.textContaining('Сделать текущим'), findsNothing);
    expect(find.textContaining('apply'), findsNothing);
    expect(find.textContaining('offerings'), findsNothing);
    expect(find.textContaining('teams'), findsNothing);
    expect(find.text('Начать новый семестр'), findsNothing);
    expect(find.byKey(const Key('students-term-filter')), findsOneWidget);
  });

  test('demo organizer lists natural subject-team starosta', () async {
    final repo = LocalStudentsRepository();
    final state = await repo.listGroupSpaceOrganizerState('g1');
    expect(state.spaceExists, isTrue);
    expect(state.assistantsSupported, isFalse);
    final natural = state.members.singleWhere((m) => m.userId == 's3');
    expect(natural.isOrganizer, isTrue);
    expect(natural.hasSubjectTeamAuthority, isTrue);
    expect(natural.hasAdminGrant, isFalse);
    expect(natural.sources, contains('subject_team'));
    expect(natural.sourceLabel, contains('subject-team'));
  });

  test(
    'demo revoke removes only explicit grant, keeps natural starosta',
    () async {
      final repo = LocalStudentsRepository();
      await repo.setGroupSpaceOrganizer(
        groupId: 'g1',
        userId: 's3',
        isOrganizer: true,
      );
      var state = await repo.listGroupSpaceOrganizerState('g1');
      var starosta = state.members.singleWhere((m) => m.userId == 's3');
      expect(starosta.hasAdminGrant, isTrue);
      expect(starosta.hasSubjectTeamAuthority, isTrue);

      await repo.setGroupSpaceOrganizer(
        groupId: 'g1',
        userId: 's3',
        isOrganizer: false,
      );
      state = await repo.listGroupSpaceOrganizerState('g1');
      starosta = state.members.singleWhere((m) => m.userId == 's3');
      expect(starosta.hasAdminGrant, isFalse);
      expect(starosta.hasSubjectTeamAuthority, isTrue);
      expect(starosta.isOrganizer, isTrue);
    },
  );

  test('demo assign/revoke explicit grant for ordinary student', () async {
    final repo = LocalStudentsRepository();
    await repo.setGroupSpaceOrganizer(
      groupId: 'g1',
      userId: 's1',
      isOrganizer: true,
    );
    var state = await repo.listGroupSpaceOrganizerState('g1');
    expect(
      state.organizers.any((m) => m.userId == 's1' && m.hasAdminGrant),
      isTrue,
    );

    await repo.setGroupSpaceOrganizer(
      groupId: 'g1',
      userId: 's1',
      isOrganizer: false,
    );
    state = await repo.listGroupSpaceOrganizerState('g1');
    final s1 = state.members.singleWhere((m) => m.userId == 's1');
    expect(s1.hasAdminGrant, isFalse);
    expect(s1.isOrganizer, isFalse);
  });

  test('organizer model parses mixed sources', () {
    final member = GroupSpaceMemberOrganizer.fromJson({
      'user_id': 'u1',
      'login': 'a',
      'name': 'A',
      'surname': 'B',
      'is_active': true,
      'has_admin_grant': true,
      'has_subject_team_authority': true,
      'subject_team_roles': ['starosta'],
      'sources': ['admin', 'subject_team'],
      'is_organizer': true,
    });
    expect(member.isOrganizer, isTrue);
    expect(member.sourceLabel, contains('explicit grant'));
    expect(member.sourceLabel, contains('subject-team'));
  });

  testWidgets('organizer dialog shows natural starosta and assign action', (
    tester,
  ) async {
    final repo = LocalStudentsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupSpaceOrganizerDialog(
            group: const GroupItem(id: 'g1', name: 'ИВТ-21', membersCount: 3),
            repository: repo,
            canManage: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Организаторы · ИВТ-21'), findsOneWidget);
    expect(find.textContaining('Старостин'), findsWidgets);
    expect(find.textContaining('subject-team'), findsWidgets);
    expect(find.text('Назначить организатором'), findsWidgets);
    // Natural-only organizer has no "Снять права организатора" for explicit path
    // on the natural row without admin grant — revoke button absent for s3.
    expect(find.text('Снять права организатора'), findsNothing);
  });

  testWidgets(
    'students screen hides organizer manage button without permission',
    (tester) async {
      final session = _TestSession(
        initialPhase: AdminSessionPhase.ready,
        capabilities: const AdminCapabilities(
          userId: 'admin-1',
          permissions: {'dashboard.view', 'students.read'},
          assignments: [],
        ),
      );
      final repo = LocalStudentsRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentsScreen(session: session, repository: repo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('ИВТ-21'), findsWidgets);
      await tester.tap(find.textContaining('ИВТ-21').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('Организаторы'), findsWidgets);
      expect(find.text('Назначить организатором'), findsNothing);
      expect(find.text('Снять права организатора'), findsNothing);
    },
  );

  testWidgets('students screen manage path can assign organizer with confirm', (
    tester,
  ) async {
    final session = _TestSession(
      initialPhase: AdminSessionPhase.ready,
      capabilities: const AdminCapabilities(
        userId: 'admin-1',
        permissions: {
          'dashboard.view',
          'students.read',
          'students.write',
          'groups.write',
        },
        assignments: [],
      ),
    );
    final repo = LocalStudentsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentsScreen(session: session, repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('ИВТ-21').first);
    await tester.pumpAndSettle();
    expect(find.text('Назначить организатором'), findsWidgets);

    await tester.tap(find.text('Назначить организатором').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Выдать'), findsOneWidget);
    await tester.tap(find.text('Назначить организатором').last);
    await tester.pumpAndSettle();

    final state = await repo.listGroupSpaceOrganizerState('g1');
    expect(state.organizers.any((m) => m.hasAdminGrant), isTrue);
    expect(find.textContaining('назначен организатором'), findsOneWidget);
  });
}
