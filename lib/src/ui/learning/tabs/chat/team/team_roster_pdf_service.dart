import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'team_roster_pdf_export_stub.dart'
    if (dart.library.io) 'team_roster_pdf_export_io.dart'
    if (dart.library.html) 'team_roster_pdf_export_web.dart';
import 'team_roster_pdf_font_stub.dart'
    if (dart.library.io) 'team_roster_pdf_font_io.dart'
    if (dart.library.html) 'team_roster_pdf_font_web.dart';

/// One row in a printable teacher roster (already sorted alphabetically).
class TeamRosterPdfRow {
  const TeamRosterPdfRow({
    required this.index,
    required this.displayName,
  });

  final int index;
  final String displayName;
}

/// Local-only PDF export: dense landscape A4 attendance grid.
/// Columns: № | ФИО | 12 empty date cells | Примечание.
/// Target: ~25 short-name rows fit on one page.
class TeamRosterPdfService {
  const TeamRosterPdfService();

  static const int attendanceColumns = 12;

  Future<void> exportAndShare({
    required String teamTitle,
    required String? groupLabel,
    required List<TeamRosterPdfRow> rows,
  }) async {
    final bytes = await buildBytes(
      teamTitle: teamTitle,
      groupLabel: groupLabel,
      rows: rows,
    );
    final stamp = _fileStamp(DateTime.now());
    final safe = _sanitizeFilename(teamTitle);
    final filename = 'vedomost_${safe}_$stamp.pdf';
    await exportRosterPdfBytes(
      bytes: bytes,
      filename: filename,
      subject: 'Ведомость: ${teamTitle.trim().isEmpty ? 'Команда' : teamTitle.trim()}',
    );
  }

  Future<Uint8List> buildBytes({
    required String teamTitle,
    required String? groupLabel,
    required List<TeamRosterPdfRow> rows,
  }) async {
    final font = await _loadFont();
    final now = DateTime.now();
    final primary = PdfColor.fromInt(0xFF7057C7);
    final line = PdfColor.fromInt(0xFFD0CBE0);
    final text = PdfColor.fromInt(0xFF1F1F2D);
    final soft = PdfColor.fromInt(0xFFF7F4FF);

    final title = teamTitle.trim().isEmpty ? 'Команда' : teamTitle.trim();
    final group = (groupLabel ?? '').trim();
    final headerLine = [
      'Ведомость посещаемости',
      title,
      if (group.isNotEmpty) 'группа $group',
      '${rows.length} чел.',
      _humanStamp(now),
      '+/−',
    ].join(' · ');

    final headers = <String>[
      '№',
      'ФИО',
      for (var i = 0; i < attendanceColumns; i++) '',
      'Примечание',
    ];

    final columnWidths = <int, pw.TableColumnWidth>{
      0: const pw.FlexColumnWidth(0.5),
      1: const pw.FlexColumnWidth(3.2),
      for (var i = 0; i < attendanceColumns; i++)
        2 + i: const pw.FlexColumnWidth(0.52),
      2 + attendanceColumns: const pw.FlexColumnWidth(1.5),
    };

    final cellAlignments = <int, pw.Alignment>{
      0: pw.Alignment.center,
      1: pw.Alignment.centerLeft,
      for (var i = 0; i < attendanceColumns; i++) 2 + i: pw.Alignment.center,
      2 + attendanceColumns: pw.Alignment.centerLeft,
    };

    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.fromLTRB(14, 12, 14, 12),
        header: (context) {
          if (context.pageNumber == 1) return pw.SizedBox();
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Text(
              '$headerLine · продолжение',
              maxLines: 1,
              style: pw.TextStyle(fontSize: 7, color: primary),
            ),
          );
        },
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '${context.pageNumber}/${context.pagesCount}',
            style: pw.TextStyle(fontSize: 7, color: primary),
          ),
        ),
        build: (context) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: pw.BoxDecoration(
              color: primary,
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(
              headerLine,
              maxLines: 1,
              style: pw.TextStyle(
                color: PdfColors.white,
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(height: 5),
          pw.TableHelper.fromTextArray(
            border: pw.TableBorder.all(color: line, width: 0.55),
            headerDecoration: pw.BoxDecoration(color: soft),
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 7,
              color: text,
            ),
            cellStyle: pw.TextStyle(fontSize: 8, color: text),
            cellAlignments: cellAlignments,
            columnWidths: columnWidths,
            headerAlignment: pw.Alignment.center,
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 2,
              vertical: 3.5,
            ),
            headers: headers,
            data: [
              for (final row in rows)
                [
                  '${row.index}',
                  _oneLineName(row.displayName),
                  for (var i = 0; i < attendanceColumns; i++) '',
                  '',
                ],
            ],
          ),
        ],
      ),
    );

    return Uint8List.fromList(await pdf.save());
  }

  /// Keeps rows single-line so ~25 people fit one landscape page.
  String _oneLineName(String raw) {
    final name = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.length <= 38) return name;
    return '${name.substring(0, 37)}…';
  }

  String _fileStamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}_${two(dt.hour)}${two(dt.minute)}';
  }

  String _humanStamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.day}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _sanitizeFilename(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[^\w\u0400-\u04FF\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (cleaned.isEmpty) return 'team';
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  Future<pw.Font> _loadFont() async {
    final preferred = await loadPreferredRosterFontBytes();
    if (preferred != null) {
      return pw.Font.ttf(preferred);
    }
    // Last resort — Lato has no Cyrillic; prefer never reaching here on device.
    final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    return pw.Font.ttf(data);
  }
}

/// Best-effort page count from PDF bytes (for tests).
int countRosterPdfPages(Uint8List bytes) {
  final s = String.fromCharCodes(bytes);
  final pagesObj = RegExp(r'/Type\s*/Pages[^e][\s\S]{0,200}?/Count\s+(\d+)')
      .firstMatch(s);
  if (pagesObj != null) {
    return int.parse(pagesObj.group(1)!);
  }
  // Fallback: count page objects (exclude /Pages).
  return RegExp(r'/Type\s*/Page[^s]').allMatches(s).length;
}
