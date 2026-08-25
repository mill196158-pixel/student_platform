import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/features/academic/students/student_import_admission.dart';
import 'package:student_platform_admin/features/academic/students/students_repository.dart';
import 'package:student_platform_admin/features/academic/students/students_screen.dart';

class _TestSession extends AdminSessionController {
  _TestSession() {
    phase = AdminSessionPhase.ready;
    capabilities = const AdminCapabilities(
      userId: 'admin-1',
      permissions: {
        'dashboard.view',
        'students.read',
        'students.write',
        'groups.write',
      },
      assignments: [],
    );
  }
}

void main() {
  test('record book 26 means admission 2026', () {
    expect(studentImportRecordBookYear('2612345'), 2026);
    expect(studentImportRecordBookYear('26-12345'), 2026);
    expect(studentImportRecordBookYear('ivanov'), isNull);
  });

  test('usual second-year student matches course-derived year', () {
    final resolved = resolveStudentImportGroup(
      academicYearStart: 2026,
      groupName: '1-СбПГС-2',
      login: '2510001',
    );
    expect(resolved.ok, isTrue);
    expect(resolved.derivedAdmissionYear, 2025);
    expect(resolved.recordBookAdmissionYear, 2025);
    expect(resolved.admissionYear, 2025);
  });

  test('rare current-year second-course intake is not merged', () {
    final resolved = resolveStudentImportGroup(
      academicYearStart: 2026,
      groupName: '1-СбПГС-2',
      login: '2610001',
    );
    expect(resolved.ok, isFalse);
    expect(resolved.error, 'record_book_admission_mismatch');
    expect(resolved.derivedAdmissionYear, 2025);
    expect(resolved.recordBookAdmissionYear, 2026);
    expect(
      studentImportErrorLabel(resolved.error),
      contains('поступлении сразу на 2 курс'),
    );
  });

  test(
    'local import creates one group and reuses it for the same year',
    () async {
      final repo = LocalStudentsRepository();
      final first = await repo.importApply([
        {
          'login': '2510001',
          'name': 'Мария',
          'surname': 'Вторая',
          'group_name': '1-СбПГС-2',
        },
        {
          'login': '2510002',
          'name': 'Игорь',
          'surname': 'Второй',
          'group_name': '1-СбПГС-2',
        },
      ], academicYearId: 'y2026');
      expect(first['updated'], 2);
      expect(first['groups_created'], 1);
      expect(first['groups_reused'], 1);
      final groups = await repo.listGroups();
      final created = groups.where((g) => g.name == '1-СбПГС-2').toList();
      expect(created, hasLength(1));
      expect(created.single.admissionYear, 2025);
      final replay = await repo.importApply([
        {
          'login': '2510001',
          'name': 'Мария',
          'surname': 'Вторая',
          'group_name': '1-СбПГС-2',
        },
        {
          'login': '2510002',
          'name': 'Игорь',
          'surname': 'Второй',
          'group_name': '1-СбПГС-2',
        },
      ], academicYearId: 'y2026');
      expect(replay['idempotent_replay'], isTrue);
    },
  );

  test('same name and different admission years stay separate', () async {
    final repo = LocalStudentsRepository();
    await repo.importApply([
      {'login': '2510001', 'group_name': '1-СбПГС-2'},
    ], academicYearId: 'y2026');
    final blocked = await repo.importDryRun([
      {'login': '2610001', 'group_name': '1-СбПГС-2'},
    ], academicYearId: 'y2026');
    expect(blocked['items'][0]['error_text'], 'record_book_admission_mismatch');
    await repo.importApply([
      {'login': '2610001', 'group_name': '1-СбПГС-1'},
    ], academicYearId: 'y2026');
    final groups = await repo.listGroups();
    expect(
      groups.where((g) => g.name == '1-СбПГС-2').single.admissionYear,
      2025,
    );
    expect(
      groups.where((g) => g.name == '1-СбПГС-1').single.admissionYear,
      2026,
    );
  });

  testWidgets('students screen asks for academic year before import', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentsScreen(
            session: _TestSession(),
            repository: LocalStudentsRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('students-import-year')), findsOneWidget);
    expect(
      find.textContaining('редкий перевод сразу на 2 курс'),
      findsOneWidget,
    );
  });
}
