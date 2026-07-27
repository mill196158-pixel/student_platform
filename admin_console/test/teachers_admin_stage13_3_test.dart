import 'dart:io';

import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/teachers/teacher_import_service.dart';
import 'package:student_platform_admin/features/academic/teachers/teacher_item.dart';
import 'package:student_platform_admin/features/academic/teachers/teachers_repository.dart';

List<int> buildTeachersFixtureXlsx() {
  final workbook = Excel.createExcel();
  final sheet = workbook[workbook.getDefaultSheet()!];
  sheet.appendRow([
    TextCellValue('ФИО'),
    TextCellValue('Кафедра'),
    TextCellValue('Должность'),
    TextCellValue('Учёная степень'),
    TextCellValue('Email'),
  ]);
  sheet.appendRow([
    TextCellValue('Иванов Иван Иванович'),
    TextCellValue('ИТ'),
    TextCellValue('Доцент'),
    TextCellValue('к.т.н.'),
    TextCellValue('ivanov@example.edu'),
  ]);
  sheet.appendRow([
    TextCellValue('Петрова Анна Сергеевна'),
    TextCellValue('Математика'),
    TextCellValue('Профессор'),
    TextCellValue('д.ф.-м.н.'),
    TextCellValue('petrova@example.edu'),
  ]);
  return workbook.encode()!;
}

void main() {
  test('local teachers repository saves and filters teacher cards', () async {
    final repository = LocalTeachersRepository(seed: const []);
    await repository.save(
      const TeacherItem(
        id: 'teacher-1',
        fullName: 'Иванов Иван Иванович',
        department: 'Кафедра',
        status: TeacherStatus.published,
      ),
    );
    final rows = await repository.list(query: 'иванов');
    expect(rows, hasLength(1));
    expect(rows.single.status, TeacherStatus.published);
  });

  test('parser reads headers and first-sheet rows', () {
    final parsed = TeacherImportService().readFirstSheet(
      buildTeachersFixtureXlsx(),
    );
    expect(parsed.headers, containsAll(['ФИО', 'Кафедра']));
    expect(
      parsed.rows.singleWhere((r) => r['ФИО']!.contains('Иванов'))['ФИО'],
      'Иванов Иван Иванович',
    );
  });

  test('checked-in fixture xlsx is readable', () {
    final file = File('test/fixtures/teachers_import_fixture.xlsx');
    expect(file.existsSync(), isTrue);
    final parsed = TeacherImportService().readFirstSheet(
      file.readAsBytesSync(),
    );
    expect(parsed.rows, hasLength(2));
    expect(suggestHeaderMapping(parsed.headers)['full_name'], 'ФИО');
  });

  test('mapping + dry-run + idempotent apply', () async {
    final repository = LocalTeachersRepository(seed: const []);
    final sheet = TeacherImportService().readFirstSheet(
      buildTeachersFixtureXlsx(),
    );
    final mapping = suggestHeaderMapping(sheet.headers);
    expect(mapping['full_name'], 'ФИО');
    final rows = [for (final raw in sheet.rows) mapImportRow(raw, mapping)];
    final dry = await repository.importDryRun(rows);
    expect(dry['rows'], 2);
    final first = await repository.importApply(rows);
    expect(first['created'], 2);
    final replay = await repository.importApply(rows);
    expect(replay['idempotent_replay'], isTrue);
    final listed = await repository.list();
    expect(listed, hasLength(2));
  });
}
