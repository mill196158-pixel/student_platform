import 'package:excel/excel.dart';

class TeacherImportSheet {
  const TeacherImportSheet({
    required this.name,
    required this.headers,
    required this.rows,
  });

  final String name;
  final List<String> headers;
  final List<Map<String, String>> rows;
}

class TeacherImportWorkbook {
  const TeacherImportWorkbook({required this.sheets});

  final List<TeacherImportSheet> sheets;
}

/// Decodes workbook sheets; server-side RPCs remain authoritative
/// for validation and persistence.
class TeacherImportService {
  TeacherImportWorkbook readWorkbook(List<int> bytes) {
    final workbook = Excel.decodeBytes(bytes);
    if (workbook.tables.isEmpty) {
      throw const FormatException('В файле нет листов.');
    }
    final sheets = <TeacherImportSheet>[];
    for (final entry in workbook.tables.entries) {
      final sheet = entry.value;
      if (sheet.rows.isEmpty) continue;
      final headers = sheet.rows.first
          .map((cell) => cell?.value?.toString().trim() ?? '')
          .toList();
      final rows = <Map<String, String>>[];
      for (final values in sheet.rows.skip(1)) {
        final row = <String, String>{};
        var hasValue = false;
        for (var index = 0; index < headers.length; index++) {
          final value = index < values.length
              ? values[index]?.value?.toString().trim() ?? ''
              : '';
          if (value.isNotEmpty) hasValue = true;
          if (headers[index].isNotEmpty) row[headers[index]] = value;
        }
        if (hasValue) rows.add(row);
      }
      sheets.add(
        TeacherImportSheet(name: entry.key, headers: headers, rows: rows),
      );
    }
    if (sheets.isEmpty) {
      throw const FormatException('В файле нет строк данных.');
    }
    return TeacherImportWorkbook(sheets: sheets);
  }

  TeacherImportSheet readFirstSheet(List<int> bytes) =>
      readWorkbook(bytes).sheets.first;
}
