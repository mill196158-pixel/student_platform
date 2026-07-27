import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/students/students_repository.dart';
import 'package:student_platform_admin/features/academic/teachers/teacher_import_service.dart';

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
    expect(items[0]['classification'], 'update');
    expect(items[1]['classification'], 'error');
    final apply = await repo.importApply(rows);
    expect(apply['updated'], 1);
    final replay = await repo.importApply(rows);
    expect(replay['idempotent_replay'], isTrue);
  });

  test('term prepare dry-run and idempotent apply', () async {
    final repo = LocalStudentsRepository();
    final dry = await repo.prepareTermDryRun('t2');
    expect(dry['missing_offerings'], greaterThan(0));
    final first = await repo.prepareTermApply(termId: 't2', setCurrent: true);
    expect(first['idempotent_replay'], isFalse);
    final second = await repo.prepareTermApply(termId: 't2', setCurrent: true);
    expect(second['idempotent_replay'], isTrue);
  });
}
