import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes FIO whitespace and case', () {
    expect(
      normalizePersonName('  Иванов\u00a0 Иван   Иванович '),
      'иванов иван иванович',
    );
  });

  test('classifies repeated FIO as duplicate', () {
    expect(
      classifyTeacherRow(
        row: {'full_name': 'Иванов Иван Иванович'},
        existingNormalizedNames: const [],
        seenNormalizedNames: const ['иванов иван иванович'],
      ),
      TeacherImportClassification.duplicate,
    );
  });

  test('suggests Russian headers and maps contacts', () {
    final mapping = suggestHeaderMapping(const [
      'ФИО',
      'Кафедра',
      'Email',
      'Сайт',
    ]);
    expect(mapping['full_name'], 'ФИО');
    expect(mapping['public_email'], 'Email');
    final row = mapImportRow(const {
      'ФИО': 'Иванов Иван Иванович',
      'Кафедра': 'ИТ',
      'Email': 'a@b.c',
      'Сайт': 'https://example.edu',
    }, mapping);
    expect(row['full_name'], 'Иванов Иван Иванович');
    expect(row['contacts_public']['public_email'], 'a@b.c');
    expect(row['contacts_public']['website'], 'https://example.edu');
  });
}
