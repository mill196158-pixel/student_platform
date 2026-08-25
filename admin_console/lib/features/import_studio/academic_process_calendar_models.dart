enum AcademicProcessAudienceKind {
  global('global', 'Все программы'),
  program('program', 'Образовательная программа'),
  plan('plan', 'Конкретный учебный план'),
  group('group', 'Конкретная группа');

  const AcademicProcessAudienceKind(this.wire, this.label);

  final String wire;
  final String label;
}

enum AcademicProcessPeriodType {
  study('study', 'Теоретическое обучение'),
  session('session', 'Сессия'),
  practice('practice', 'Практика'),
  holidays('holidays', 'Каникулы'),
  gia('gia', 'ГИА'),
  other('other', 'Другое');

  const AcademicProcessPeriodType(this.wire, this.label);

  final String wire;
  final String label;
}

class AcademicProcessReference {
  const AcademicProcessReference({
    required this.id,
    required this.label,
    this.parentId,
    this.admissionYear,
    this.nominalSemesters,
    this.status,
  });

  final String id;
  final String label;
  final String? parentId;
  final int? admissionYear;
  final int? nominalSemesters;
  final String? status;
}

class AcademicProcessCalendarReferences {
  const AcademicProcessCalendarReferences({
    required this.years,
    required this.programs,
    required this.plans,
    required this.groups,
  });

  final List<AcademicProcessReference> years;
  final List<AcademicProcessReference> programs;
  final List<AcademicProcessReference> plans;
  final List<AcademicProcessReference> groups;
}

class AcademicProcessPeriodDraft {
  const AcademicProcessPeriodDraft({
    required this.periodKey,
    required this.type,
    required this.courseNumber,
    required this.termInYear,
    required this.startsOn,
    required this.endsOn,
    this.sourceNote,
  });

  final String periodKey;
  final AcademicProcessPeriodType type;
  final int courseNumber;
  final int termInYear;
  final DateTime? startsOn;
  final DateTime? endsOn;
  final String? sourceNote;

  int get semesterNumber => ((courseNumber - 1) * 2) + termInYear;

  Map<String, dynamic> toJson() => {
    'period_key': periodKey.trim(),
    'period_type': type.wire,
    'course_number': courseNumber,
    'term_in_year': termInYear,
    'starts_on': _date(startsOn),
    'ends_on': _date(endsOn),
    'source_note': sourceNote?.trim(),
  };

  static String? _date(DateTime? value) {
    if (value == null) return null;
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }
}

class AcademicProcessDryRunResult {
  const AcademicProcessDryRunResult({
    required this.ok,
    required this.applyEnabled,
    required this.publishEnabled,
    required this.total,
    required this.newCount,
    required this.errorCount,
    required this.items,
  });

  final bool ok;
  final bool applyEnabled;
  final bool publishEnabled;
  final int total;
  final int newCount;
  final int errorCount;
  final List<Map<String, dynamic>> items;

  factory AcademicProcessDryRunResult.fromJson(Map<String, dynamic> json) {
    final summary = Map<String, dynamic>.from(
      (json['summary'] as Map?) ?? const {},
    );
    return AcademicProcessDryRunResult(
      ok: json['ok'] == true,
      applyEnabled: json['apply_enabled'] == true,
      publishEnabled: json['publish_enabled'] == true,
      total: int.tryParse('${summary['total'] ?? 0}') ?? 0,
      newCount: int.tryParse('${summary['new'] ?? 0}') ?? 0,
      errorCount: int.tryParse('${summary['error'] ?? 0}') ?? 0,
      items: [
        for (final item in (json['items'] as List? ?? const []))
          Map<String, dynamic>.from(item as Map),
      ],
    );
  }
}
