import 'package:excel/excel.dart';

/// Builds downloadable Excel templates aligned with [admin_import_mapping] aliases.
class ImportStudioTemplateService {
  List<int> buildTemplateBytes(String domain) {
    final columns = importStudioTemplateDisplayColumns[domain];
    if (columns == null || columns.isEmpty) {
      throw ArgumentError('No template for domain $domain');
    }

    final workbook = Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet()!;
    workbook.rename(defaultSheet, _sheetName(domain));
    final sheet = workbook[_sheetName(domain)];

    sheet.appendRow([
      for (final column in columns) TextCellValue(column.header),
    ]);
    if (columns.any((column) => column.sampleRow != null)) {
      sheet.appendRow([
        for (final column in columns)
          TextCellValue(column.sampleRow ?? ''),
      ]);
    }

    final encoded = workbook.encode();
    if (encoded == null || encoded.isEmpty) {
      throw StateError('Failed to encode template for $domain');
    }
    return encoded;
  }

  String suggestedFileName(String domain) =>
      'import_studio_${domain}_template.xlsx';

  String _sheetName(String domain) {
    return switch (domain) {
      'teachers' => 'Преподаватели',
      'subjects' => 'Предметы',
      'students' => 'Студенты',
      'groups' => 'Группы',
      'curriculum' => 'Учебный план',
      'terms' => 'Семестры',
      _ => domain,
    };
  }
}

class ImportStudioTemplateColumn {
  const ImportStudioTemplateColumn({
    required this.header,
    this.sampleRow,
  });

  final String header;
  final String? sampleRow;
}

/// Human-readable headers for templates (match admin_import_mapping aliases).
const importStudioTemplateDisplayColumns = <String, List<ImportStudioTemplateColumn>>{
  'teachers': [
    ImportStudioTemplateColumn(
      header: 'ФИО',
      sampleRow: 'Иванов Иван Иванович',
    ),
    ImportStudioTemplateColumn(header: 'Email', sampleRow: 'ivanov@example.edu'),
    ImportStudioTemplateColumn(header: 'Кафедра', sampleRow: 'ИТ'),
    ImportStudioTemplateColumn(header: 'Должность', sampleRow: 'Доцент'),
    ImportStudioTemplateColumn(header: 'Учёная степень', sampleRow: 'к.т.н.'),
    ImportStudioTemplateColumn(header: 'О преподавателе'),
  ],
  'subjects': [
    ImportStudioTemplateColumn(header: 'Предмет', sampleRow: 'Математика'),
    ImportStudioTemplateColumn(header: 'Описание'),
    ImportStudioTemplateColumn(header: 'Кафедра', sampleRow: 'ИТ'),
    ImportStudioTemplateColumn(header: 'Форма контроля', sampleRow: 'экзамен'),
    ImportStudioTemplateColumn(header: 'Требования'),
    ImportStudioTemplateColumn(header: 'Чему научится'),
  ],
  'students': [
    ImportStudioTemplateColumn(header: 'Логин', sampleRow: 'student01'),
    ImportStudioTemplateColumn(header: 'Имя', sampleRow: 'Иван'),
    ImportStudioTemplateColumn(header: 'Фамилия', sampleRow: 'Иванов'),
    ImportStudioTemplateColumn(header: 'Группа', sampleRow: 'ИТ-101'),
  ],
  'groups': [
    ImportStudioTemplateColumn(header: 'Группа', sampleRow: 'ИТ-101'),
  ],
  'curriculum': [
    ImportStudioTemplateColumn(header: 'Группа', sampleRow: 'ИТ-101'),
    ImportStudioTemplateColumn(header: 'Предмет', sampleRow: 'Математика'),
    ImportStudioTemplateColumn(header: 'Семестр', sampleRow: '1'),
    ImportStudioTemplateColumn(header: 'Зачётные единицы', sampleRow: '4'),
    ImportStudioTemplateColumn(header: 'Часы', sampleRow: '144'),
    ImportStudioTemplateColumn(header: 'Форма контроля', sampleRow: 'экзамен'),
    ImportStudioTemplateColumn(header: 'Блок'),
    ImportStudioTemplateColumn(header: 'Индекс'),
  ],
  'terms': [
    ImportStudioTemplateColumn(header: 'Учебный год', sampleRow: '2025/2026'),
    ImportStudioTemplateColumn(header: 'Семестр', sampleRow: 'Осенний'),
    ImportStudioTemplateColumn(header: 'Номер в году', sampleRow: '1'),
    ImportStudioTemplateColumn(header: 'Начало', sampleRow: '2025-09-01'),
    ImportStudioTemplateColumn(header: 'Окончание', sampleRow: '2026-01-31'),
  ],
};
