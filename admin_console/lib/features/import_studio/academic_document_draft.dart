const curriculumDocumentContractVersion = 'curriculum-document-v1';
const curriculumDocumentParserVersion = 'local-layout-v1';
const academicDocumentMaxBytes = 20 * 1024 * 1024;
const academicDocumentMaxPages = 500;

enum AcademicDocumentDiagnosis {
  textPdf,
  xlsx,
  manualRequired,
  unsupported,
  error,
}

enum AcademicStudyForm {
  fullTime('full_time', 'Очная'),
  partTime('part_time', 'Очно-заочная'),
  extramural('extramural', 'Заочная'),
  mixed('mixed', 'Смешанная');

  const AcademicStudyForm(this.wire, this.label);

  final String wire;
  final String label;
}

enum CurriculumRowDisposition {
  undecided('Требуется решение'),
  occurrence('Дисциплина плана'),
  heading('Заголовок блока'),
  excluded('Не импортировать');

  const CurriculumRowDisposition(this.label);

  final String label;
}

class AcademicSourceRegion {
  const AcademicSourceRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
}

class AcademicTextFragment {
  const AcademicTextFragment({
    required this.page,
    required this.text,
    required this.region,
  });

  final int page;
  final String text;
  final AcademicSourceRegion region;
}

class AcademicTextPage {
  const AcademicTextPage({
    required this.page,
    required this.width,
    required this.height,
    required this.fullText,
    required this.fragments,
  });

  final int page;
  final double width;
  final double height;
  final String fullText;
  final List<AcademicTextFragment> fragments;
}

class CurriculumDraftMetadata {
  const CurriculumDraftMetadata({
    this.directionCode,
    this.directionName,
    this.profileName,
    this.qualification,
    this.studyForm,
    this.admissionYear,
    this.nominalSemesters,
    this.durationYears,
    this.planCode,
  });

  final String? directionCode;
  final String? directionName;
  final String? profileName;
  final String? qualification;
  final AcademicStudyForm? studyForm;
  final int? admissionYear;
  final int? nominalSemesters;
  final int? durationYears;
  final String? planCode;

  CurriculumDraftMetadata copyWith({
    String? directionCode,
    String? directionName,
    String? profileName,
    String? qualification,
    AcademicStudyForm? studyForm,
    int? admissionYear,
    int? nominalSemesters,
    int? durationYears,
    String? planCode,
  }) {
    return CurriculumDraftMetadata(
      directionCode: directionCode ?? this.directionCode,
      directionName: directionName ?? this.directionName,
      profileName: profileName ?? this.profileName,
      qualification: qualification ?? this.qualification,
      studyForm: studyForm ?? this.studyForm,
      admissionYear: admissionYear ?? this.admissionYear,
      nominalSemesters: nominalSemesters ?? this.nominalSemesters,
      durationYears: durationYears ?? this.durationYears,
      planCode: planCode ?? this.planCode,
    );
  }
}

class CurriculumDraftRow {
  const CurriculumDraftRow({
    required this.candidateKey,
    required this.subjectIndex,
    required this.subjectName,
    required this.sourcePage,
    required this.sourceRegion,
    this.semesterNumber,
    this.hoursTotal,
    this.credits,
    this.controlForm,
    this.blockName,
    this.rawText = '',
    this.blockingIssues = const [],
    this.warnings = const [],
    this.reviewerConfirmed = false,
    this.disposition = CurriculumRowDisposition.occurrence,
    this.isAggregateCandidate = false,
  });

  /// Temporary review key only. It is never a final source occurrence key.
  final String candidateKey;
  final String subjectIndex;
  final String subjectName;
  final int? semesterNumber;
  final int? hoursTotal;
  final num? credits;
  final String? controlForm;
  final String? blockName;
  final int sourcePage;
  final AcademicSourceRegion? sourceRegion;
  final String rawText;
  final List<String> blockingIssues;
  final List<String> warnings;
  final bool reviewerConfirmed;
  final CurriculumRowDisposition disposition;
  final bool isAggregateCandidate;

  bool get requiresReview =>
      !reviewerConfirmed ||
      disposition == CurriculumRowDisposition.undecided ||
      subjectName.trim().isEmpty ||
      (disposition == CurriculumRowDisposition.occurrence &&
          semesterNumber == null) ||
      blockingIssues.isNotEmpty;

  CurriculumDraftRow copyWith({
    String? subjectIndex,
    String? subjectName,
    int? semesterNumber,
    bool clearSemesterNumber = false,
    int? hoursTotal,
    bool clearHoursTotal = false,
    num? credits,
    bool clearCredits = false,
    String? controlForm,
    bool clearControlForm = false,
    String? blockName,
    List<String>? blockingIssues,
    List<String>? warnings,
    bool? reviewerConfirmed,
    CurriculumRowDisposition? disposition,
    bool? isAggregateCandidate,
  }) {
    return CurriculumDraftRow(
      candidateKey: candidateKey,
      subjectIndex: subjectIndex ?? this.subjectIndex,
      subjectName: subjectName ?? this.subjectName,
      semesterNumber: clearSemesterNumber
          ? null
          : (semesterNumber ?? this.semesterNumber),
      hoursTotal: clearHoursTotal ? null : (hoursTotal ?? this.hoursTotal),
      credits: clearCredits ? null : (credits ?? this.credits),
      controlForm: clearControlForm ? null : (controlForm ?? this.controlForm),
      blockName: blockName ?? this.blockName,
      sourcePage: sourcePage,
      sourceRegion: sourceRegion,
      rawText: rawText,
      blockingIssues: blockingIssues ?? this.blockingIssues,
      warnings: warnings ?? this.warnings,
      reviewerConfirmed: reviewerConfirmed ?? this.reviewerConfirmed,
      disposition: disposition ?? this.disposition,
      isAggregateCandidate: isAggregateCandidate ?? this.isAggregateCandidate,
    );
  }
}

class AcademicDocumentDraft {
  const AcademicDocumentDraft({
    required this.diagnosis,
    required this.fileName,
    required this.fileSize,
    required this.localSha256,
    required this.pageCount,
    required this.metadata,
    required this.rows,
    this.sheetName,
    this.blockingIssues = const [],
    this.warnings = const [],
  });

  final AcademicDocumentDiagnosis diagnosis;
  final String fileName;
  final int fileSize;
  final String localSha256;
  final int pageCount;
  final String? sheetName;
  final CurriculumDraftMetadata metadata;
  final List<CurriculumDraftRow> rows;
  final List<String> blockingIssues;
  final List<String> warnings;

  String get contractVersion => curriculumDocumentContractVersion;
  String get parserVersion => curriculumDocumentParserVersion;

  int get unresolvedRowCount => rows.where((row) => row.requiresReview).length;

  bool get isManualRequired =>
      diagnosis == AcademicDocumentDiagnosis.manualRequired;

  /// Apply is deliberately unavailable in this extraction-only substage.
  bool get canContinue => false;
}
