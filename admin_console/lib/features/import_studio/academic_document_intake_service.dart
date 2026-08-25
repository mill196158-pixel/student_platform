import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'academic_document_draft.dart';
import 'academic_pdf_extractor.dart';
import 'curriculum_document_parser.dart';
import 'import_studio_workbook_service.dart';

class AcademicDocumentIntakeService {
  AcademicDocumentIntakeService({
    AcademicPdfExtractor? pdfExtractor,
    CurriculumDocumentParser? parser,
    ImportStudioWorkbookService? workbookService,
  }) : _pdfExtractor = pdfExtractor ?? const PdfrxAcademicPdfExtractor(),
       _parser = parser ?? const CurriculumDocumentParser(),
       _workbookService = workbookService ?? ImportStudioWorkbookService();

  final AcademicPdfExtractor _pdfExtractor;
  final CurriculumDocumentParser _parser;
  final ImportStudioWorkbookService _workbookService;

  Future<AcademicDocumentDraft> read({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      throw const FormatException('Файл пуст.');
    }
    if (bytes.lengthInBytes > academicDocumentMaxBytes) {
      throw const FormatException(
        'Файл больше 20 МБ. Выберите уменьшенную копию.',
      );
    }

    final extension = fileName.split('.').last.toLowerCase();
    final localHash = sha256.convert(bytes).toString();
    switch (extension) {
      case 'pdf':
        return _readPdf(bytes: bytes, fileName: fileName, localHash: localHash);
      case 'xlsx':
        return _readXlsx(
          bytes: bytes,
          fileName: fileName,
          localHash: localHash,
        );
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
        return AcademicDocumentDraft(
          diagnosis: AcademicDocumentDiagnosis.manualRequired,
          fileName: fileName,
          fileSize: bytes.lengthInBytes,
          localSha256: localHash,
          pageCount: 1,
          metadata: const CurriculumDraftMetadata(),
          rows: const [],
          blockingIssues: const [
            'Изображение принято как исходник, но текст не распознавался.',
            'OCR в Web Admin недоступен: заполните черновик вручную.',
          ],
          warnings: const ['Документ не считается успешно распознанным.'],
        );
      default:
        throw const FormatException(
          'Поддерживаются PDF, XLSX, PNG, JPG и WEBP.',
        );
    }
  }

  Future<AcademicDocumentDraft> _readPdf({
    required Uint8List bytes,
    required String fileName,
    required String localHash,
  }) async {
    final extraction = await _pdfExtractor.extract(
      bytes: bytes,
      fileName: fileName,
    );
    if (extraction.pages.length > academicDocumentMaxPages) {
      throw const FormatException(
        'В PDF больше 500 страниц. Разделите документ на части.',
      );
    }
    if (extraction.characterCount < 40) {
      return AcademicDocumentDraft(
        diagnosis: AcademicDocumentDiagnosis.manualRequired,
        fileName: fileName,
        fileSize: bytes.lengthInBytes,
        localSha256: localHash,
        pageCount: extraction.pages.length,
        metadata: const CurriculumDraftMetadata(),
        rows: const [],
        blockingIssues: const [
          'В PDF нет доступного текстового слоя.',
          'OCR в Web Admin пока недоступен: заполните черновик вручную.',
        ],
        warnings: const ['Документ не считается успешно распознанным.'],
      );
    }

    final parsed = _parser.parsePdfPages(extraction.pages);
    final blockers = <String>[
      if (parsed.rows.isEmpty) 'Не найдены индексированные строки дисциплин.',
      if (parsed.metadata.directionCode == null)
        'Не распознан код направления.',
      if (parsed.metadata.profileName == null)
        'Не распознан профиль программы.',
      if (parsed.metadata.admissionYear == null)
        'Не распознан год начала подготовки.',
      if (parsed.metadata.studyForm == null) 'Не распознана форма обучения.',
    ];
    return AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.textPdf,
      fileName: fileName,
      fileSize: bytes.lengthInBytes,
      localSha256: localHash,
      pageCount: extraction.pages.length,
      metadata: parsed.metadata,
      rows: parsed.rows,
      blockingIssues: blockers,
      warnings: const [
        'SHA-256 вычислен локально; сервером не подтверждён.',
        'Источник не загружен, происхождение документа не подтверждено.',
        'Автоматически извлечённые семестры, часы и формы контроля требуют подтверждения.',
      ],
    );
  }

  AcademicDocumentDraft _readXlsx({
    required Uint8List bytes,
    required String fileName,
    required String localHash,
  }) {
    final workbook = _workbookService.readWorkbook(bytes);
    final sheet = workbook.sheets.first;
    final rows = <CurriculumDraftRow>[];
    for (var index = 0; index < sheet.rows.length; index++) {
      final source = sheet.rows[index];
      final subjectName = _value(source, const [
        'subject_name',
        'предмет',
        'наименование',
        'дисциплина',
      ]);
      if (subjectName.isEmpty) continue;
      final subjectIndex = _value(source, const [
        'subject_index',
        'индекс',
        'код',
      ]);
      final semester = int.tryParse(
        _value(source, const ['semester_number', 'семестр']),
      );
      final hours = int.tryParse(
        _value(source, const ['hours_total', 'часы', 'всего часов']),
      );
      final creditsRaw = _value(source, const [
        'credits',
        'з.е.',
        'зачетные единицы',
        'зачётные единицы',
      ]).replaceAll(',', '.');
      final credits = num.tryParse(creditsRaw);
      final control = _value(source, const [
        'control_form',
        'форма контроля',
        'контроль',
      ]);
      final assessments = semester == null
          ? const <CurriculumDraftAssessment>[]
          : _assessmentTypes(control)
                .map(
                  (type) => CurriculumDraftAssessment(
                    type: type,
                    semesterNumber: semester,
                    rawValue: control,
                    sourcePage: 1,
                    sourceRegion: null,
                  ),
                )
                .toList(growable: false);
      rows.add(
        CurriculumDraftRow(
          candidateKey: 'candidate-${sheet.name}-${index + 2}',
          subjectIndex: subjectIndex,
          subjectName: subjectName,
          hoursTotal: hours,
          credits: credits,
          occurrences: semester == null
              ? const []
              : [
                  CurriculumDraftOccurrence(
                    semesterNumber: semester,
                    sourcePage: 1,
                    sourceRegion: null,
                    assessments: assessments,
                  ),
                ],
          sourcePage: 1,
          sourceRegion: null,
          rawText: source.values.join(' | '),
          blockingIssues: [
            if (semester == null) 'semester_required',
            'review_confirmation_required',
          ],
          warnings: [
            if (subjectIndex.isEmpty) 'Индекс дисциплины не заполнен.',
          ],
        ),
      );
    }

    return AcademicDocumentDraft(
      diagnosis: AcademicDocumentDiagnosis.xlsx,
      fileName: fileName,
      fileSize: bytes.lengthInBytes,
      localSha256: localHash,
      pageCount: 0,
      sheetName: sheet.name,
      metadata: const CurriculumDraftMetadata(),
      rows: rows,
      blockingIssues: [
        'Заполните программу, форму обучения и год поступления.',
        if (rows.isEmpty) 'В первом листе не найдены строки дисциплин.',
      ],
      warnings: const [
        'SHA-256 вычислен локально; сервером не подтверждён.',
        'Источник не загружен, происхождение документа не подтверждено.',
      ],
    );
  }

  String _value(Map<String, String> row, List<String> aliases) {
    for (final entry in row.entries) {
      final key = entry.key.trim().toLowerCase().replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      if (aliases.contains(key)) return entry.value.trim();
    }
    return '';
  }

  List<CurriculumAssessmentType> _assessmentTypes(String raw) {
    if (raw.trim().isEmpty) return const [];
    final normalized = raw.toLowerCase().replaceAll('ё', 'е');
    final values = <CurriculumAssessmentType>[
      if (normalized.contains('экзамен')) CurriculumAssessmentType.exam,
      if (normalized.contains('зачет с оцен') ||
          normalized.contains('дифференцирован'))
        CurriculumAssessmentType.gradedCredit
      else if (normalized.contains('зачет'))
        CurriculumAssessmentType.credit,
      if (normalized.contains('курсовой проект') ||
          RegExp(r'\bкп\b').hasMatch(normalized))
        CurriculumAssessmentType.courseProject,
      if (normalized.contains('курсовая работа') ||
          RegExp(r'\bкр\b').hasMatch(normalized))
        CurriculumAssessmentType.courseWork,
      if (normalized.contains('контрольная') ||
          RegExp(r'\bконтр').hasMatch(normalized))
        CurriculumAssessmentType.controlWork,
    ];
    return values.isEmpty ? const [CurriculumAssessmentType.unknown] : values;
  }
}
