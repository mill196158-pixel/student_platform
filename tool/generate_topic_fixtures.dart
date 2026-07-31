import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

Uint8List buildDocxFixture() {
  const documentXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>1. Тема из фикстуры</w:t></w:r></w:p>
    <w:p><w:r><w:t>2) Вторая тема</w:t></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Тема из таблицы</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
  </w:body>
</w:document>''';
  final archive = Archive()
    ..addFile(
      ArchiveFile(
        'word/document.xml',
        documentXml.length,
        utf8.encode(documentXml),
      ),
    )
    ..addFile(
      ArchiveFile(
        '[Content_Types].xml',
        0,
        utf8.encode(
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
        ),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

List<int> buildXlsxFixture() {
  final workbook = Excel.createExcel();
  final sheet = workbook[workbook.getDefaultSheet()!];
  sheet.appendRow([
    TextCellValue('№'),
    TextCellValue('Тема'),
  ]);
  sheet.appendRow([TextCellValue('1'), TextCellValue('Фикстура Excel')]);
  sheet.appendRow([TextCellValue('2'), TextCellValue('Вторая тема')]);
  return workbook.encode()!;
}

void main() {
  final dir = Directory('test/fixtures/topics')..createSync(recursive: true);
  File('${dir.path}/minimal.docx').writeAsBytesSync(buildDocxFixture());
  File('${dir.path}/minimal.xlsx').writeAsBytesSync(buildXlsxFixture());
  stdout.writeln('Generated topic fixtures in ${dir.path}');
}
