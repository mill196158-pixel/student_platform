import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/composite_topic_ocr_adapter.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_models.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_normalizer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_parser.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_pdf_page_renderer.dart';

class _FixtureOcrAdapter extends FakeTopicOcrAdapter {
  const _FixtureOcrAdapter(super.text);
}

class _FixturePdfExtractor extends TopicPdfTextExtractor {
  const _FixturePdfExtractor(this.text, {this.needsOcr = false});

  final String text;
  final bool needsOcr;

  @override
  PdfTextExtractionResult extract(Uint8List bytes) {
    return PdfTextExtractionResult(text: text, needsOcr: needsOcr);
  }
}

class _FixturePdfPageRenderer extends TopicPdfPageRenderer {
  const _FixturePdfPageRenderer({
    this.pageCountValue = 2,
    this.pageTexts = const {
      0: '1. PDF OCR A',
      1: '2. PDF OCR B',
    },
  });

  final int pageCountValue;
  final Map<int, String> pageTexts;

  @override
  Future<int> pageCount(Uint8List pdfBytes) async => pageCountValue;

  @override
  Future<Uint8List> renderPage({
    required Uint8List pdfBytes,
    required int pageIndex,
    double dpi = topicListOcrRenderDpi,
  }) async {
    final text = pageTexts[pageIndex] ?? '';
    return Uint8List.fromList(utf8.encode(text));
  }
}

class _PageTextOcrAdapter extends TopicOcrAdapter {
  @override
  Future<String> recognize(Uint8List bytes) async {
    return utf8.decode(bytes);
  }
}

List<int> buildTopicsFixtureXlsx({
  List<String>? headers,
  List<List<String>>? rows,
  Map<String, List<List<String>>>? extraSheets,
}) {
  final workbook = Excel.createExcel();
  final defaultName = workbook.getDefaultSheet()!;
  final sheet = workbook[defaultName];
  final headerRow = headers ??
      [
        '№',
        'Тема',
        'Примечание',
      ];
  sheet.appendRow([for (final h in headerRow) TextCellValue(h)]);
  for (final row in rows ??
      [
        ['1', 'Введение в SQL', ''],
        ['2', 'Нормализация БД', ''],
        ['3', 'Индексы', ''],
      ]) {
    sheet.appendRow([for (final cell in row) TextCellValue(cell)]);
  }

  for (final entry in (extraSheets ?? const {}).entries) {
    final extra = workbook[entry.key];
    extra.appendRow([for (final h in headerRow) TextCellValue(h)]);
    for (final row in entry.value) {
      extra.appendRow([for (final cell in row) TextCellValue(cell)]);
    }
  }
  return workbook.encode()!;
}

Uint8List buildTopicsFixtureDocx({
  required List<String> paragraphLines,
  List<String>? tableCellLines,
}) {
  final paragraphXml = paragraphLines
      .map(
        (line) =>
            '<w:p><w:r><w:t xml:space="preserve">${_xmlEscape(line)}</w:t></w:r></w:p>',
      )
      .join();

  final tableXml = tableCellLines == null
      ? ''
      : '<w:tbl>${tableCellLines.map((cell) => '<w:tr><w:tc><w:p><w:r><w:t>${_xmlEscape(cell)}</w:t></w:r></w:p></w:tc></w:tr>').join()}</w:tbl>';

  final documentXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    $paragraphXml
    $tableXml
  </w:body>
</w:document>
''';

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
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'),
      ),
    );

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

String _xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

void main() {
  group('normalizeTopicLines', () {
    test('strips numbering markers but keeps title numbers', () {
      final topics = normalizeTopicLines([
        '1. Введение',
        '2) Нормализация',
        'а) Индексы',
        'Тема 12: анализ данных',
        '- Транзакции',
      ]);

      expect(topics.map((t) => t.title), [
        'Введение',
        'Нормализация',
        'Индексы',
        'Тема 12: анализ данных',
        'Транзакции',
      ]);
    });

    test('dedupes case-insensitively', () {
      final topics = normalizeTopicLines([
        'Тема A',
        'тема a',
        'ТЕМА A',
        'Тема B',
      ]);
      expect(topics, hasLength(2));
      expect(topics.first.title, 'Тема A');
      expect(topics.last.title, 'Тема B');
    });

    test('enforces 200 topic limit', () {
      final lines = List.generate(250, (i) => 'Тема $i');
      final topics = normalizeTopicLines(lines);
      expect(topics, hasLength(topicListMaxTopics));
      expect(topicLimitWarning(250), contains('200'));
    });

    test('merges soft-wrapped lines', () {
      final topics = normalizeTopicLines([
        '1. Длинная тема про',
        'базы данных',
        '2. Короткая',
      ]);
      expect(topics, hasLength(2));
      expect(topics.first.title, 'Длинная тема про базы данных');
      expect(topics.last.title, 'Короткая');
    });
  });

  group('TopicListParser excel', () {
    test('detects topic column by header and parses rows', () async {
      final bytes = Uint8List.fromList(buildTopicsFixtureXlsx());
      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: bytes,
        sourceName: 'topics.xlsx',
      );

      expect(result.hasError, isFalse);
      expect(result.kind, TopicParseSourceKind.excel);
      expect(result.suggestedExcelColumn, 1);
      expect(result.excelHeaders, contains('Тема'));
      expect(result.topics.map((t) => t.title), [
        'Введение в SQL',
        'Нормализация БД',
        'Индексы',
      ]);
    });

    test('supports explicit excel column index', () async {
      final bytes = Uint8List.fromList(
        buildTopicsFixtureXlsx(
          headers: ['Название', 'Код'],
          rows: [
            ['Alpha', '001'],
            ['Beta', '002'],
          ],
        ),
      );
      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: bytes,
        sourceName: 'topics.xlsx',
        excelColumnIndex: 0,
      );

      expect(result.topics.map((t) => t.title), ['Alpha', 'Beta']);
      expect(result.suggestedExcelColumn, 0);
    });

    test('supports selecting a non-first excel sheet', () async {
      final bytes = Uint8List.fromList(
        buildTopicsFixtureXlsx(
          rows: [
            ['1', 'Тема с первого листа', ''],
          ],
          extraSheets: {
            'Темы': [
              ['1', 'Тема со второго листа', ''],
              ['2', 'Ещё тема со второго листа', ''],
            ],
          },
        ),
      );
      final parser = TopicListParser();
      final first = await parser.parseBytes(
        bytes: bytes,
        sourceName: 'topics.xlsx',
      );
      expect(first.excelSheetNames, contains('Темы'));
      expect(
          first.topics.map((t) => t.title), contains('Тема с первого листа'));

      final second = await parser.parseBytes(
        bytes: bytes,
        sourceName: 'topics.xlsx',
        excelSheetName: 'Темы',
      );
      expect(second.selectedExcelSheet, 'Темы');
      expect(second.topics.map((t) => t.title), [
        'Тема со второго листа',
        'Ещё тема со второго листа',
      ]);
    });
  });

  group('TopicListParser word', () {
    test('parses paragraphs, lists, and table cells', () async {
      final bytes = buildTopicsFixtureDocx(
        paragraphLines: [
          '1. Тема из абзаца',
          '2) Вторая тема',
        ],
        tableCellLines: [
          'Тема из таблицы',
          'Ещё тема из таблицы',
        ],
      );

      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: bytes,
        sourceName: 'topics.docx',
      );

      expect(result.kind, TopicParseSourceKind.word);
      expect(result.topics.map((t) => t.title), [
        'Тема из абзаца',
        'Вторая тема',
        'Тема из таблицы',
        'Ещё тема из таблицы',
      ]);
    });

    test('reads committed minimal.docx fixture', () async {
      final fixture = File('test/fixtures/topics/minimal.docx');
      expect(fixture.existsSync(), isTrue);
      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: fixture.readAsBytesSync(),
        sourceName: 'minimal.docx',
      );
      expect(result.topics.map((t) => t.title), contains('Тема из фикстуры'));
    });
  });

  group('TopicListParser committed fixtures', () {
    test('reads committed minimal.xlsx fixture', () async {
      final fixture = File('test/fixtures/topics/minimal.xlsx');
      expect(fixture.existsSync(), isTrue);
      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: fixture.readAsBytesSync(),
        sourceName: 'minimal.xlsx',
      );
      expect(result.topics.map((t) => t.title), contains('Фикстура Excel'));
    });
  });

  group('TopicListParser pdf', () {
    test('uses injectable pdf extractor fixture', () async {
      final parser = TopicListParser(
        pdfExtractor: const _FixturePdfExtractor(
          '1. PDF тема A\n2. PDF тема B\n',
        ),
      );
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
        sourceName: 'topics.pdf',
      );

      expect(result.topics.map((t) => t.title), ['PDF тема A', 'PDF тема B']);
      expect(result.needsOcr, isFalse);
    });

    test('marks needsOcr when extractor returns empty', () async {
      final parser = TopicListParser(
        pdfExtractor: const _FixturePdfExtractor('', needsOcr: true),
      );
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
        sourceName: 'scan.pdf',
      );

      expect(result.topics, isEmpty);
      expect(result.needsOcr, isTrue);
      expect(result.warnings, isNotEmpty);
    });

    test('OCR fallback uses injectable pdf page renderer', () async {
      final parser = TopicListParser(
        pdfExtractor: const _FixturePdfExtractor('', needsOcr: true),
        ocrAdapter: _PageTextOcrAdapter(),
        pdfPageRenderer: const _FixturePdfPageRenderer(
          pageTexts: {
            0: '1. OCR из PDF',
            1: '2. Вторая тема PDF',
          },
        ),
      );
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
        sourceName: 'scan.pdf',
        pdfOcrPageIndices: const [0, 1],
      );

      expect(result.hasError, isFalse);
      expect(result.topics.map((t) => t.title), [
        'OCR из PDF',
        'Вторая тема PDF',
      ]);
      expect(result.needsOcr, isFalse);
    });
  });

  group('TopicListParser image OCR', () {
    test('uses OCR adapter fixture', () async {
      final parser = TopicListParser(
        ocrAdapter: const _FixtureOcrAdapter(
          '1. OCR тема\n2. Вторая OCR тема',
        ),
      );
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        sourceName: 'photo.png',
      );

      expect(result.kind, TopicParseSourceKind.image);
      expect(result.topics.map((t) => t.title), [
        'OCR тема',
        'Вторая OCR тема',
      ]);
    });

    test('default OCR adapter returns Russian error', () async {
      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        sourceName: 'photo.jpg',
      );

      expect(result.hasError, isTrue);
      expect(result.error, contains('недоступно'));
    });

    test('OCR fixture handles numbering and wrapped lines', () async {
      final parser = TopicListParser(
        ocrAdapter: const _FixtureOcrAdapter(
          '1. Первая OCR тема\nпродолжение строки\n2) Вторая OCR тема',
        ),
      );
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        sourceName: 'scan.png',
      );

      expect(result.topics.map((t) => t.title), [
        'Первая OCR тема продолжение строки',
        'Вторая OCR тема',
      ]);
    });
  });

  group('TopicListReviewController', () {
    test('supports manual correction workflow', () {
      final controller = TopicListReviewController();
      controller.applyParseResult(
        TopicParseResult(
          sourceName: 'manual',
          kind: TopicParseSourceKind.manual,
          topics: const [
            TopicDraft(title: 'Тема 1'),
            TopicDraft(title: 'Тема 2'),
          ],
        ),
      );

      controller.editAt(0, title: 'Исправленная тема 1', capacity: 2);
      controller.add(title: 'Новая тема');
      controller.reorder(2, 0);
      controller.mergeAdjacent(0);
      controller.dedupe();
      controller.setCapacityAt(0, 3);

      final json = controller.toPublishJson();
      expect(json.first['title'], isA<String>());
      expect(json.first['capacity'], 3);
      expect(json.first.containsKey('sort_order'), isTrue);
    });

    test('remove and merge adjacent', () {
      final controller = TopicListReviewController(
        initial: const [
          TopicDraft(title: 'A'),
          TopicDraft(title: 'B'),
          TopicDraft(title: 'C'),
        ],
      );
      controller.removeAt(1);
      expect(controller.topics.map((t) => t.title), ['A', 'C']);

      controller.mergeAdjacent(0);
      expect(controller.topics.single.title, 'A C');
    });

    test('splitLine divides merged OCR title', () {
      final controller = TopicListReviewController(
        initial: const [
          TopicDraft(title: 'Тема A — Тема B'),
        ],
      );
      controller.splitLine(0);
      expect(controller.topics.map((t) => t.title), ['Тема A', 'Тема B']);
    });
  });

  group('Topic OCR adapter contract', () {
    test('default adapter returns Russian error on desktop VM', () async {
      final parser = TopicListParser();
      final result = await parser.parseBytes(
        bytes: Uint8List.fromList([1]),
        sourceName: 'photo.png',
      );
      expect(result.hasError, isTrue);
      expect(result.error, contains('недоступно'));
    });

    test('composite prefers Cyrillic fallback over weak Latin OCR', () async {
      final adapter = CompositeTopicOcrAdapter(
        primary: const FakeTopicOcrAdapter('1. Topic one\n2. Topic two'),
        cyrillicFallback: const FakeTopicOcrAdapter(
          '1. Первая тема\n2. Вторая тема\n3. Третья тема',
        ),
      );
      final text = await adapter.recognize(Uint8List.fromList([1, 2, 3]));
      expect(text, contains('Первая тема'));
      expect(text, contains('Третья тема'));
    });
  });
}
