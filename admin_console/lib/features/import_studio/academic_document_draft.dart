const curriculumDocumentContractVersion = 'curriculum-document-v2';
const curriculumDocumentParserVersion = 'local-layout-v2';
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

enum CurriculumAssessmentType {
  exam('exam', 'Экзамен'),
  credit('credit', 'Зачёт'),
  gradedCredit('graded_credit', 'Зачёт с оценкой'),
  courseProject('course_project', 'Курсовой проект'),
  courseWork('course_work', 'Курсовая работа'),
  controlWork('control_work', 'Контрольная работа'),
  unknown('unknown', 'Неизвестная форма');

  const CurriculumAssessmentType(this.wire, this.label);

  final String wire;
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

class CurriculumDraftAssessment {
  const CurriculumDraftAssessment({
    required this.type,
    required this.semesterNumber,
    required this.rawValue,
    required this.sourcePage,
    required this.sourceRegion,
    this.reviewerConfirmed = false,
    this.warnings = const [],
  });

  final CurriculumAssessmentType type;
  final int? semesterNumber;
  final String rawValue;
  final int sourcePage;
  final AcademicSourceRegion? sourceRegion;
  final bool reviewerConfirmed;
  final List<String> warnings;

  CurriculumDraftAssessment copyWith({
    CurriculumAssessmentType? type,
    int? semesterNumber,
    bool clearSemesterNumber = false,
    bool? reviewerConfirmed,
    List<String>? warnings,
  }) {
    return CurriculumDraftAssessment(
      type: type ?? this.type,
      semesterNumber: clearSemesterNumber
          ? null
          : (semesterNumber ?? this.semesterNumber),
      rawValue: rawValue,
      sourcePage: sourcePage,
      sourceRegion: sourceRegion,
      reviewerConfirmed: reviewerConfirmed ?? this.reviewerConfirmed,
      warnings: warnings ?? this.warnings,
    );
  }
}

class CurriculumDraftOccurrence {
  const CurriculumDraftOccurrence({
    required this.semesterNumber,
    required this.sourcePage,
    required this.sourceRegion,
    this.workload = const {},
    this.assessments = const [],
    this.reviewerConfirmed = false,
    this.warnings = const [],
  });

  final int semesterNumber;
  final int sourcePage;
  final AcademicSourceRegion? sourceRegion;
  final Map<String, num> workload;
  final List<CurriculumDraftAssessment> assessments;
  final bool reviewerConfirmed;
  final List<String> warnings;

  CurriculumDraftOccurrence copyWith({
    int? semesterNumber,
    Map<String, num>? workload,
    List<CurriculumDraftAssessment>? assessments,
    bool? reviewerConfirmed,
    List<String>? warnings,
  }) {
    return CurriculumDraftOccurrence(
      semesterNumber: semesterNumber ?? this.semesterNumber,
      sourcePage: sourcePage,
      sourceRegion: sourceRegion,
      workload: workload ?? this.workload,
      assessments: assessments ?? this.assessments,
      reviewerConfirmed: reviewerConfirmed ?? this.reviewerConfirmed,
      warnings: warnings ?? this.warnings,
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
    this.subjectId,
    this.hoursTotal,
    this.credits,
    this.occurrences = const [],
    this.unresolvedAssessments = const [],
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
  final String? subjectId;
  final String subjectIndex;
  final String subjectName;
  final List<CurriculumDraftOccurrence> occurrences;
  final List<CurriculumDraftAssessment> unresolvedAssessments;
  final int? hoursTotal;
  final num? credits;
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
          occurrences.isEmpty) ||
      (disposition == CurriculumRowDisposition.occurrence &&
          occurrences.any(
            (occurrence) =>
                !occurrence.reviewerConfirmed ||
                occurrence.assessments.any(
                  (assessment) => !assessment.reviewerConfirmed,
                ),
          )) ||
      (disposition == CurriculumRowDisposition.occurrence &&
          unresolvedAssessments.isNotEmpty) ||
      blockingIssues.isNotEmpty;

  CurriculumDraftRow copyWith({
    String? subjectIndex,
    String? subjectName,
    String? subjectId,
    bool clearSubjectId = false,
    List<CurriculumDraftOccurrence>? occurrences,
    List<CurriculumDraftAssessment>? unresolvedAssessments,
    int? hoursTotal,
    bool clearHoursTotal = false,
    num? credits,
    bool clearCredits = false,
    String? blockName,
    List<String>? blockingIssues,
    List<String>? warnings,
    bool? reviewerConfirmed,
    CurriculumRowDisposition? disposition,
    bool? isAggregateCandidate,
  }) {
    return CurriculumDraftRow(
      candidateKey: candidateKey,
      subjectId: clearSubjectId ? null : (subjectId ?? this.subjectId),
      subjectIndex: subjectIndex ?? this.subjectIndex,
      subjectName: subjectName ?? this.subjectName,
      occurrences: occurrences ?? this.occurrences,
      unresolvedAssessments:
          unresolvedAssessments ?? this.unresolvedAssessments,
      hoursTotal: clearHoursTotal ? null : (hoursTotal ?? this.hoursTotal),
      credits: clearCredits ? null : (credits ?? this.credits),
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
