/// Aggregated subject difficulty used by Info / exams / subject info.
///
/// Display rule matches the existing academic-v2 screens:
/// prefer global average, otherwise local; never show a synthetic `0 / 5`.
class SubjectDifficultySummary {
  final double avgDifficultyGlobal;
  final double avgDifficultyLocal;

  const SubjectDifficultySummary({
    required this.avgDifficultyGlobal,
    required this.avgDifficultyLocal,
  });

  const SubjectDifficultySummary.empty()
      : avgDifficultyGlobal = 0,
        avgDifficultyLocal = 0;

  /// Raw effective value used for calculations (not rounded).
  double? get effectiveDifficulty {
    if (avgDifficultyGlobal > 0) return avgDifficultyGlobal;
    if (avgDifficultyLocal > 0) return avgDifficultyLocal;
    return null;
  }

  bool get hasRating => effectiveDifficulty != null;

  /// Info-tab friendly label: `4.2 / 5` or `Пока нет оценок`.
  String get displayLabel => formatDifficultyLabel(effectiveDifficulty);

  /// Compact label used by existing SubjectInfo / exams copy.
  String get compactLabel =>
      formatDifficultyLabel(effectiveDifficulty, emptyLabel: 'нет оценок');

  static String formatDifficultyLabel(
    double? value, {
    String emptyLabel = 'Пока нет оценок',
  }) {
    if (value == null || value <= 0) return emptyLabel;
    return '${value.toStringAsFixed(1)} / 5';
  }
}

/// Average difficulty of rated subjects in the student's current semester.
class SessionDifficultySummary {
  final double? average;
  final int ratedCount;
  final int totalCount;

  const SessionDifficultySummary({
    required this.average,
    required this.ratedCount,
    required this.totalCount,
  });

  const SessionDifficultySummary.empty()
      : average = null,
        ratedCount = 0,
        totalCount = 0;

  bool get hasRatings => average != null && ratedCount > 0;

  String get valueLabel =>
      SubjectDifficultySummary.formatDifficultyLabel(average);

  String get coverageLabel {
    if (!hasRatings) {
      return 'Оценки появятся после первых голосов';
    }
    return 'Оценено $ratedCount из $totalCount ${_subjectWord(totalCount)}';
  }

  /// Computes session difficulty from already-mapped subject summaries.
  ///
  /// Only subjects of [currentSemesterNumber] with a non-null
  /// [SubjectDifficultySummary.effectiveDifficulty] are included.
  /// User votes are never averaged here.
  factory SessionDifficultySummary.compute({
    required int? currentSemesterNumber,
    required Iterable<SubjectDifficultySummary> currentSemesterDifficulties,
    required int currentSemesterSubjectCount,
  }) {
    if (currentSemesterNumber == null || currentSemesterSubjectCount <= 0) {
      return const SessionDifficultySummary.empty();
    }

    final rated = <double>[];
    for (final item in currentSemesterDifficulties) {
      final value = item.effectiveDifficulty;
      if (value != null) rated.add(value);
    }

    if (rated.isEmpty) {
      return SessionDifficultySummary(
        average: null,
        ratedCount: 0,
        totalCount: currentSemesterSubjectCount,
      );
    }

    final sum = rated.fold<double>(0, (acc, value) => acc + value);
    return SessionDifficultySummary(
      average: sum / rated.length,
      ratedCount: rated.length,
      totalCount: currentSemesterSubjectCount,
    );
  }

  /// Convenience overload for subject-like records.
  factory SessionDifficultySummary.fromSubjects({
    required int? currentSemesterNumber,
    required Iterable<
            ({int? semesterNumber, SubjectDifficultySummary difficulty})>
        subjects,
  }) {
    if (currentSemesterNumber == null) {
      return const SessionDifficultySummary.empty();
    }

    final current = subjects
        .where((item) => item.semesterNumber == currentSemesterNumber)
        .toList(growable: false);

    return SessionDifficultySummary.compute(
      currentSemesterNumber: currentSemesterNumber,
      currentSemesterDifficulties: current.map((item) => item.difficulty),
      currentSemesterSubjectCount: current.length,
    );
  }

  static String _subjectWord(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    // After «из N …»: 1 предмета, 2+ предметов.
    if (mod10 == 1 && mod100 != 11) return 'предмета';
    return 'предметов';
  }
}
