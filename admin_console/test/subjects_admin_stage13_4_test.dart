import 'dart:io';

import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/subjects/subject_item.dart';
import 'package:student_platform_admin/features/academic/subjects/subjects_repository.dart';
import 'package:student_platform_admin/features/academic/teachers/teacher_import_service.dart';

List<int> buildSubjectsFixtureXlsx() {
  final workbook = Excel.createExcel();
  final sheet = workbook[workbook.getDefaultSheet()!];
  sheet.appendRow([
    TextCellValue('Предмет'),
    TextCellValue('Кафедра'),
    TextCellValue('Форма контроля'),
    TextCellValue('Краткое описание'),
  ]);
  sheet.appendRow([
    TextCellValue('Базы данных'),
    TextCellValue('ИТ'),
    TextCellValue('Экзамен'),
    TextCellValue('SQL и модели данных'),
  ]);
  sheet.appendRow([
    TextCellValue('Информационная безопасность'),
    TextCellValue('ИТ'),
    TextCellValue('Зачёт'),
    TextCellValue('Основы защиты информации'),
  ]);
  return workbook.encode()!;
}

void main() {
  test('local subjects repository filters and saves', () async {
    final repository = LocalSubjectsRepository(seed: const []);
    await repository.save(
      const SubjectItem(
        id: 's1',
        canonicalName: 'Базы данных',
        department: 'ИТ',
        status: SubjectStatus.published,
      ),
    );
    final rows = await repository.list(query: 'базы');
    expect(rows, hasLength(1));
  });

  test('fixture xlsx mapping dry-run and idempotent apply', () async {
    final bytes = buildSubjectsFixtureXlsx();
    final file = File('test/fixtures/subjects_import_fixture.xlsx');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    final sheet = TeacherImportService().readFirstSheet(bytes);
    final mapping = suggestSubjectHeaderMapping(sheet.headers);
    expect(mapping['canonical_name'], 'Предмет');
    final rows = [for (final raw in sheet.rows) mapImportRow(raw, mapping)];
    final repository = LocalSubjectsRepository(seed: const []);
    final dry = await repository.importDryRun(rows);
    expect(dry['rows'], 2);
    final first = await repository.importApply(rows);
    expect(first['created'], 2);
    final replay = await repository.importApply(rows);
    expect(replay['idempotent_replay'], isTrue);
  });
}
