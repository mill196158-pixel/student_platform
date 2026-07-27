import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

import 'topic_list_models.dart';
import 'topic_list_normalizer.dart';
import 'topic_pdf_page_renderer.dart';

/// Extracts plain text from PDF bytes for topic-list parsing.
abstract class TopicPdfTextExtractor {
  const TopicPdfTextExtractor();

  PdfTextExtractionResult extract(Uint8List bytes);
}

class PdfTextExtractionResult {
  const PdfTextExtractionResult({
    required this.text,
    this.needsOcr = false,
  });

  final String text;
  final bool needsOcr;
}

/// Best-effort embedded-text extraction without heavy PDF runtimes.
class DefaultTopicPdfTextExtractor extends TopicPdfTextExtractor {
  const DefaultTopicPdfTextExtractor();

  @override
  PdfTextExtractionResult extract(Uint8List bytes) {
    final text = _extractParenthesizedStrings(bytes);
    if (text.trim().isEmpty) {
      return const PdfTextExtractionResult(text: '', needsOcr: true);
    }
    return PdfTextExtractionResult(text: text, needsOcr: false);
  }

  static String _extractParenthesizedStrings(Uint8List bytes) {
    final content = latin1.decode(bytes, allowInvalid: true);
    final buffer = StringBuffer();
    final pattern = RegExp(r'\(([^\\)]*(?:\\.[^\\)]*)*)\)');
    for (final match in pattern.allMatches(content)) {
      final chunk = match.group(1);
      if (chunk == null || chunk.trim().isEmpty) continue;
      if (_looksLikeBinary(chunk)) continue;
      buffer.writeln(_unescapePdfString(chunk));
    }
    return buffer.toString();
  }

  static bool _looksLikeBinary(String value) {
    final nonPrintable = value.runes.where((r) => r < 32 && r != 10 && r != 13);
    return nonPrintable.length > value.length ~/ 4;
  }

  static String _unescapePdfString(String value) {
    return value
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\\', r'\')
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')');
  }
}

/// OCR hook for image-based topic lists.
abstract class TopicOcrAdapter {
  const TopicOcrAdapter();

  Future<String> recognize(Uint8List bytes);

  /// Releases native recognizer resources when applicable.
  Future<void> dispose() async {}
}

/// Test/dev fake that returns fixed OCR text without native bindings.
class FakeTopicOcrAdapter extends TopicOcrAdapter {
  const FakeTopicOcrAdapter(this.text);

  final String text;

  @override
  Future<String> recognize(Uint8List bytes) async => text;
}

/// Default OCR adapter — platform OCR is wired later (e.g. ML Kit).
class UnavailableTopicOcrAdapter extends TopicOcrAdapter {
  const UnavailableTopicOcrAdapter();

  @override
  Future<String> recognize(Uint8List bytes) {
    throw UnsupportedError(
      'Распознавание текста с изображения недоступно на этой платформе.',
    );
  }
}

/// Local-only topic list parser. Returns [TopicParseResult] for review UI.
class TopicListParser {
  TopicListParser({
    TopicPdfTextExtractor? pdfExtractor,
    TopicOcrAdapter? ocrAdapter,
    TopicPdfPageRenderer? pdfPageRenderer,
  })  : _pdfExtractor = pdfExtractor ?? const DefaultTopicPdfTextExtractor(),
        _ocrAdapter = ocrAdapter ?? const UnavailableTopicOcrAdapter(),
        _pdfPageRenderer =
            pdfPageRenderer ?? const UnavailableTopicPdfPageRenderer();

  final TopicPdfTextExtractor _pdfExtractor;
  final TopicOcrAdapter _ocrAdapter;
  final TopicPdfPageRenderer _pdfPageRenderer;

  static const _excelExtensions = {'.xlsx', '.xlsm', '.xltx', '.xltm'};
  static const _wordExtensions = {'.docx'};
  static const _pdfExtensions = {'.pdf'};
  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.bmp',
    '.gif',
    '.heic',
  };

  static final _topicHeaderPattern = RegExp(
    r'тема|topic|название|title|name|subject',
    caseSensitive: false,
  );

  /// Parses a file from [path].
  Future<TopicParseResult> parseFile({
    required String path,
    int? excelColumnIndex,
    String? excelSheetName,
    TopicOcrAdapter? ocr,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return _errorResult(
        sourceName: _basename(path),
        kind: _kindFromName(path),
        message: 'Файл не найден: $path',
      );
    }

    final length = await file.length();
    if (length > topicListMaxFileBytes) {
      return _errorResult(
        sourceName: _basename(path),
        kind: _kindFromName(path),
        message: 'Файл слишком большой (${length ~/ 1024} КБ). '
            'Максимум ${topicListMaxFileBytes ~/ (1024 * 1024)} МБ.',
      );
    }

    late Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      return _errorResult(
        sourceName: _basename(path),
        kind: _kindFromName(path),
        message: _protectedFileMessage(e),
      );
    }

    return parseBytes(
      bytes: bytes,
      sourceName: _basename(path),
      excelColumnIndex: excelColumnIndex,
      excelSheetName: excelSheetName,
      ocr: ocr,
    );
  }

  /// Parses in-memory bytes (e.g. from file picker).
  Future<TopicParseResult> parseBytes({
    required Uint8List bytes,
    required String sourceName,
    int? excelColumnIndex,
    String? excelSheetName,
    TopicOcrAdapter? ocr,
    List<int>? pdfOcrPageIndices,
    TopicPdfPageRenderer? pdfPageRenderer,
  }) async {
    if (bytes.length > topicListMaxFileBytes) {
      return _errorResult(
        sourceName: sourceName,
        kind: _kindFromName(sourceName),
        message: 'Файл слишком большой (${bytes.length ~/ 1024} КБ). '
            'Максимум ${topicListMaxFileBytes ~/ (1024 * 1024)} МБ.',
      );
    }

    final kind = _kindFromName(sourceName);
    final ocrAdapter = ocr ?? _ocrAdapter;
    final pageRenderer = pdfPageRenderer ?? _pdfPageRenderer;

    try {
      switch (kind) {
        case TopicParseSourceKind.excel:
          return _parseExcel(
            bytes,
            sourceName,
            excelColumnIndex: excelColumnIndex,
            excelSheetName: excelSheetName,
          );
        case TopicParseSourceKind.word:
          return _parseWord(bytes, sourceName);
        case TopicParseSourceKind.pdf:
          return _parsePdf(
            bytes,
            sourceName,
            ocrAdapter: ocrAdapter,
            pdfOcrPageIndices: pdfOcrPageIndices,
            pdfPageRenderer: pageRenderer,
          );
        case TopicParseSourceKind.image:
          return _parseImage(bytes, sourceName, ocrAdapter);
        case TopicParseSourceKind.manual:
          return _errorResult(
            sourceName: sourceName,
            kind: kind,
            message: 'Ручной ввод не поддерживает разбор файла.',
          );
      }
    } on FormatException catch (e) {
      return _errorResult(
        sourceName: sourceName,
        kind: kind,
        message: e.message,
      );
    } catch (e) {
      return _errorResult(
        sourceName: sourceName,
        kind: kind,
        message: 'Не удалось разобрать файл: $e',
      );
    }
  }

  Future<TopicParseResult> _parseExcel(
    Uint8List bytes,
    String sourceName, {
    int? excelColumnIndex,
    String? excelSheetName,
  }) async {
    final Excel workbook;
    try {
      workbook = Excel.decodeBytes(bytes);
    } catch (_) {
      throw const FormatException(
        'Не удалось открыть Excel-файл. Проверьте, что файл не повреждён '
        'и не защищён паролем.',
      );
    }

    if (workbook.tables.isEmpty) {
      throw const FormatException('В Excel-файле нет листов.');
    }

    final sheetNames = workbook.tables.keys.toList(growable: false);
    final selectedName = (excelSheetName != null &&
            excelSheetName.trim().isNotEmpty &&
            workbook.tables.containsKey(excelSheetName.trim()))
        ? excelSheetName.trim()
        : sheetNames.first;
    final sheet = workbook.tables[selectedName]!;
    if (sheet.rows.isEmpty) {
      throw FormatException('Лист «$selectedName» пуст.');
    }

    final headers = sheet.rows.first
        .map((cell) => cell?.value?.toString().trim() ?? '')
        .toList();

    final columnIndex =
        excelColumnIndex ?? _detectBestExcelColumn(sheet.rows, headers);

    final rawLines = <String>[];
    for (final row in sheet.rows.skip(1)) {
      if (columnIndex >= row.length) continue;
      final value = row[columnIndex]?.value?.toString().trim() ?? '';
      if (value.isNotEmpty) rawLines.add(value);
    }

    final topics = normalizeTopicLines(rawLines);
    final warnings = <String>[];
    final limit = topicLimitWarning(rawLines.length);
    if (limit != null) warnings.add(limit);
    if (sheetNames.length > 1) {
      warnings.add('Выбран лист «$selectedName» из ${sheetNames.length}.');
    }

    if (topics.isEmpty) {
      throw const FormatException(
        'В выбранном столбце Excel не найдено тем.',
      );
    }

    return TopicParseResult(
      sourceName: sourceName,
      kind: TopicParseSourceKind.excel,
      topics: topics,
      suggestedExcelColumn: columnIndex,
      excelHeaders: headers,
      excelSheetNames: sheetNames,
      selectedExcelSheet: selectedName,
      warnings: warnings,
    );
  }

  Future<TopicParseResult> _parseWord(
    Uint8List bytes,
    String sourceName,
  ) async {
    final lines = _extractDocxLines(bytes);
    if (lines.isEmpty) {
      throw const FormatException(
        'Word-документ не содержит распознаваемого текста.',
      );
    }

    final topics = normalizeTopicLines(lines);
    final warnings = <String>[];
    final limit = topicLimitWarning(lines.length);
    if (limit != null) warnings.add(limit);

    return TopicParseResult(
      sourceName: sourceName,
      kind: TopicParseSourceKind.word,
      topics: topics,
      warnings: warnings,
    );
  }

  Future<TopicParseResult> _parsePdf(
    Uint8List bytes,
    String sourceName, {
    required TopicOcrAdapter ocrAdapter,
    List<int>? pdfOcrPageIndices,
    required TopicPdfPageRenderer pdfPageRenderer,
  }) async {
    final extraction = _pdfExtractor.extract(bytes);
    if (extraction.needsOcr && extraction.text.trim().isEmpty) {
      if (pdfOcrPageIndices == null || pdfOcrPageIndices.isEmpty) {
        return TopicParseResult(
          sourceName: sourceName,
          kind: TopicParseSourceKind.pdf,
          topics: const [],
          needsOcr: true,
          warnings: const [
            'В PDF не найден встроенный текст. Выберите страницы для OCR.',
          ],
        );
      }

      return _parsePdfWithOcr(
        bytes: bytes,
        sourceName: sourceName,
        pageIndices: pdfOcrPageIndices,
        ocrAdapter: ocrAdapter,
        pdfPageRenderer: pdfPageRenderer,
      );
    }

    final lines = _linesFromText(extraction.text);
    final topics = normalizeTopicLines(lines);
    final warnings = <String>[];
    final limit = topicLimitWarning(lines.length);
    if (limit != null) warnings.add(limit);

    if (topics.isEmpty) {
      return TopicParseResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.pdf,
        topics: const [],
        needsOcr: extraction.needsOcr,
        warnings: const ['PDF не содержит распознаваемых тем.'],
      );
    }

    return TopicParseResult(
      sourceName: sourceName,
      kind: TopicParseSourceKind.pdf,
      topics: topics,
      needsOcr: extraction.needsOcr,
      warnings: warnings,
    );
  }

  Future<TopicParseResult> _parsePdfWithOcr({
    required Uint8List bytes,
    required String sourceName,
    required List<int> pageIndices,
    required TopicOcrAdapter ocrAdapter,
    required TopicPdfPageRenderer pdfPageRenderer,
  }) async {
    final uniquePages = pageIndices.toSet().toList()..sort();
    if (uniquePages.length > topicListMaxOcrPages) {
      return _errorResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.pdf,
        message:
            'Можно распознать не более $topicListMaxOcrPages страниц PDF за раз.',
      );
    }

    try {
      final pageCount = await pdfPageRenderer.pageCount(bytes);
      for (final index in uniquePages) {
        if (index < 0 || index >= pageCount) {
          return _errorResult(
            sourceName: sourceName,
            kind: TopicParseSourceKind.pdf,
            message:
                'Страница ${index + 1} отсутствует в PDF (всего $pageCount).',
          );
        }
      }

      final textBuffer = StringBuffer();
      for (final index in uniquePages) {
        final imageBytes = await pdfPageRenderer.renderPage(
          pdfBytes: bytes,
          pageIndex: index,
          dpi: topicListOcrRenderDpi,
        );
        final pageText = await ocrAdapter.recognize(imageBytes);
        if (pageText.trim().isNotEmpty) {
          if (textBuffer.isNotEmpty) textBuffer.writeln();
          textBuffer.write(pageText.trim());
        }
      }

      final combined = textBuffer.toString();
      if (combined.trim().isEmpty) {
        throw const FormatException(
          'На выбранных страницах PDF не найдено тем для импорта.',
        );
      }

      final lines = _linesFromText(combined);
      final topics = normalizeTopicLines(lines);
      final warnings = <String>[
        'Текст получен через OCR по ${uniquePages.length} стр. PDF.',
      ];
      final limit = topicLimitWarning(lines.length);
      if (limit != null) warnings.add(limit);

      if (topics.isEmpty) {
        throw const FormatException(
          'На выбранных страницах PDF не найдено тем для импорта.',
        );
      }

      return TopicParseResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.pdf,
        topics: topics,
        needsOcr: false,
        warnings: warnings,
      );
    } on UnsupportedError catch (e) {
      return _errorResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.pdf,
        message: e.message ?? 'OCR недоступен.',
      );
    } on FormatException catch (e) {
      return _errorResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.pdf,
        message: e.message,
      );
    }
  }

  /// Returns PDF page count for page-picker UI.
  Future<int> pdfPageCount({
    required Uint8List bytes,
    TopicPdfPageRenderer? pdfPageRenderer,
  }) {
    return (pdfPageRenderer ?? _pdfPageRenderer).pageCount(bytes);
  }

  Future<TopicParseResult> _parseImage(
    Uint8List bytes,
    String sourceName,
    TopicOcrAdapter ocr,
  ) async {
    try {
      final text = await ocr.recognize(bytes);
      final lines = _linesFromText(text);
      final topics = normalizeTopicLines(lines);
      final warnings = <String>[];
      final limit = topicLimitWarning(lines.length);
      if (limit != null) warnings.add(limit);

      if (topics.isEmpty) {
        throw const FormatException(
          'На изображении не найдено тем для импорта.',
        );
      }

      return TopicParseResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.image,
        topics: topics,
        warnings: warnings,
      );
    } on UnsupportedError catch (e) {
      return _errorResult(
        sourceName: sourceName,
        kind: TopicParseSourceKind.image,
        message: e.message ?? 'OCR недоступен.',
      );
    }
  }

  static List<String> _extractDocxLines(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException(
        'Не удалось открыть Word-файл. Проверьте, что файл не повреждён.',
      );
    }

    ArchiveFile? documentEntry;
    for (final file in archive.files) {
      if (file.name == 'word/document.xml') {
        documentEntry = file;
        break;
      }
    }
    if (documentEntry == null) {
      throw const FormatException('Word-документ не содержит document.xml.');
    }

    final xml = utf8.decode(documentEntry.content as List<int>);
    return _parseDocxDocumentXml(xml);
  }

  static List<String> _parseDocxDocumentXml(String xml) {
    final lines = <String>[];
    final paragraphPattern = RegExp(r'<w:p\b[^>]*>(.*?)</w:p>', dotAll: true);
    final textPattern = RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>');

    for (final paragraph in paragraphPattern.allMatches(xml)) {
      final body = paragraph.group(1) ?? '';
      final buffer = StringBuffer();
      for (final textMatch in textPattern.allMatches(body)) {
        buffer.write(textMatch.group(1));
      }
      final line = buffer.toString().trim();
      if (line.isNotEmpty) lines.add(line);
    }
    return lines;
  }

  static int _detectBestExcelColumn(
    List<List<Data?>> rows,
    List<String> headers,
  ) {
    for (var i = 0; i < headers.length; i++) {
      if (_topicHeaderPattern.hasMatch(headers[i])) return i;
    }

    final columnCount = rows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );

    var bestIndex = 0;
    var bestScore = -1;
    for (var col = 0; col < columnCount; col++) {
      var score = 0;
      for (final row in rows.skip(1)) {
        if (col >= row.length) continue;
        final value = row[col]?.value?.toString().trim() ?? '';
        if (value.length >= 2) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        bestIndex = col;
      }
    }
    return bestIndex;
  }

  static List<String> _linesFromText(String text) {
    return text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  static TopicParseSourceKind _kindFromName(String name) {
    final lower = name.toLowerCase();
    for (final ext in _excelExtensions) {
      if (lower.endsWith(ext)) return TopicParseSourceKind.excel;
    }
    for (final ext in _wordExtensions) {
      if (lower.endsWith(ext)) return TopicParseSourceKind.word;
    }
    for (final ext in _pdfExtensions) {
      if (lower.endsWith(ext)) return TopicParseSourceKind.pdf;
    }
    for (final ext in _imageExtensions) {
      if (lower.endsWith(ext)) return TopicParseSourceKind.image;
    }
    return TopicParseSourceKind.manual;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  static String _protectedFileMessage(FileSystemException e) {
    final message = e.message.toLowerCase();
    if (message.contains('permission') ||
        message.contains('denied') ||
        message.contains('access')) {
      return 'Нет доступа к файлу. Проверьте права или снимите защиту.';
    }
    return 'Не удалось прочитать файл: ${e.message}';
  }

  static TopicParseResult _errorResult({
    required String sourceName,
    required TopicParseSourceKind kind,
    required String message,
  }) {
    return TopicParseResult(
      sourceName: sourceName,
      kind: kind,
      topics: const [],
      error: message,
    );
  }
}
