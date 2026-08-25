import 'academic_document_draft.dart';

class CurriculumDocumentParser {
  const CurriculumDocumentParser();

  ParsedCurriculumDocument parsePdfPages(List<AcademicTextPage> pages) {
    final fullText = pages.map((page) => page.fullText).join('\n');
    final fragmentText = pages
        .expand((page) => page.fragments)
        .map((fragment) => fragment.text)
        .join('\n');
    final metadata = _parseMetadata('$fullText\n$fragmentText', pages);
    final lines = <_LayoutLine>[];
    for (final page in pages) {
      lines.addAll(_groupLines(page));
    }

    final layoutRows = pages
        .expand(
          (page) => _parseCoordinateTable(
            page,
            nominalSemesters: metadata.nominalSemesters ?? 8,
          ),
        )
        .toList(growable: false);
    final candidateRows = layoutRows.isEmpty
        ? _parseCandidateRows(lines)
        : layoutRows;
    final allIndexes = candidateRows.map((row) => row.subjectIndex).toSet();
    final rows = candidateRows
        .map((row) {
          final hasChildren = allIndexes.any(
            (index) => index.startsWith('${row.subjectIndex}.'),
          );
          if (!hasChildren &&
              !row.subjectName.toLowerCase().contains(
                'элективные дисциплины',
              )) {
            return row;
          }
          return row.copyWith(
            disposition: CurriculumRowDisposition.undecided,
            isAggregateCandidate: true,
            blockingIssues: [
              ...row.blockingIssues,
              'aggregate_parent_decision_required',
            ],
            warnings: [...row.warnings, 'Строка может быть заголовком выбора.'],
          );
        })
        .toList(growable: false);

    return ParsedCurriculumDocument(
      metadata: metadata,
      rows: rows,
      characterCount: fullText.trim().length,
    );
  }

  CurriculumDraftMetadata _parseMetadata(
    String source,
    List<AcademicTextPage> pages,
  ) {
    final normalized = source.replaceAll('\r', '');
    final directionCode = _firstGroup(
      normalized,
      RegExp(r'\b(\d{2}\.\d{2}\.\d{2})\b'),
    );
    final qualification = _firstGroup(
      normalized,
      RegExp(
        r'Квалификация:\s*([^\n]+?)(?=\s+Год\s+начала)',
        caseSensitive: false,
      ),
    );
    final studyFormRaw = _firstGroup(
      normalized,
      RegExp(r'Форма\s+обучения:\s*([^\n]+)', caseSensitive: false),
    );
    final admissionYear = int.tryParse(
      _firstGroup(
            normalized,
            RegExp(
              r'Год\s+начала\s+подготовки[^0-9]*(\d{4})',
              caseSensitive: false,
            ),
          ) ??
          '',
    );
    final durationYears = int.tryParse(
      _firstGroup(
            normalized,
            RegExp(
              r'Срок\s+получения\s+образования:\s*(\d+)',
              caseSensitive: false,
            ),
          ) ??
          '',
    );
    final planCode = _firstGroup(
      normalized,
      RegExp(r"'([^'\n]+\.plx)'", caseSensitive: false),
    );
    final profileFromText = _firstGroup(
      normalized,
      RegExp(
        r'направленность\s*\(профиль\)\s*:\s*([^,\n]+)',
        caseSensitive: false,
      ),
    );
    final profileName = _validProfileName(profileFromText)
        ? profileFromText
        : _profileNameFromLayout(pages);
    final directionName =
        _directionName(normalized, directionCode) ??
        _directionNameFromLayout(pages, directionCode);
    final semesters = RegExp(r'Семестр\s+(\d+)', caseSensitive: false)
        .allMatches(normalized)
        .map((match) {
          return int.tryParse(match.group(1) ?? '') ?? 0;
        })
        .where((value) => value > 0);

    return CurriculumDraftMetadata(
      directionCode: directionCode,
      directionName: directionName,
      profileName: profileName,
      qualification: qualification,
      studyForm: _studyForm(studyFormRaw),
      admissionYear: admissionYear,
      nominalSemesters: semesters.isEmpty
          ? (durationYears == null ? null : durationYears * 2)
          : semesters.reduce((a, b) => a > b ? a : b),
      durationYears: durationYears,
      planCode: planCode,
    );
  }

  List<_LayoutLine> _groupLines(AcademicTextPage page) {
    final fragments =
        page.fragments
            .where((fragment) => fragment.text.trim().isNotEmpty)
            .toList()
          ..sort((a, b) {
            final y = b.region.bottom.compareTo(a.region.bottom);
            return y == 0 ? a.region.left.compareTo(b.region.left) : y;
          });
    final lines = <_LayoutLine>[];
    for (final fragment in fragments) {
      final centerY = (fragment.region.top + fragment.region.bottom) / 2;
      _LayoutLine? target;
      for (final candidate in lines.reversed.take(6)) {
        if (candidate.page == page.page &&
            (candidate.centerY - centerY).abs() <= 2.5) {
          target = candidate;
          break;
        }
      }
      if (target == null) {
        lines.add(
          _LayoutLine(page: page.page, centerY: centerY, fragments: [fragment]),
        );
      } else {
        target.fragments.add(fragment);
      }
    }
    for (final line in lines) {
      line.fragments.sort((a, b) => a.region.left.compareTo(b.region.left));
    }
    lines.sort((a, b) {
      final pageOrder = a.page.compareTo(b.page);
      return pageOrder == 0 ? b.centerY.compareTo(a.centerY) : pageOrder;
    });
    return lines;
  }

  List<CurriculumDraftRow> _parseCandidateRows(List<_LayoutLine> lines) {
    final rows = <CurriculumDraftRow>[];
    var ordinal = 0;
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex];
      final joined = line.text;
      final match = _subjectIndexPattern.firstMatch(joined);
      if (match == null) continue;

      final subjectIndex = match.group(1)!.trim();
      var subjectName = (match.group(2) ?? '').trim();
      final originalTail = subjectName;
      subjectName = _stripNumericTail(subjectName);
      final hadNumericTail = subjectName != originalTail;
      final sourceFragments = <AcademicTextFragment>[...line.fragments];
      final rawParts = <String>[joined];

      if (!hadNumericTail && lineIndex + 1 < lines.length) {
        final next = lines[lineIndex + 1];
        if (next.page == line.page &&
            _subjectIndexPattern.firstMatch(next.text) == null) {
          final continuation = _stripNumericTail(next.text);
          if (_looksLikeNameContinuation(continuation)) {
            subjectName = '$subjectName $continuation'.trim();
            sourceFragments.addAll(next.fragments);
            rawParts.add(next.text);
          }
        }
      }

      subjectName = subjectName
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(RegExp(r'[-–—]\s*$'), '')
          .trim();
      if (subjectName.isEmpty) continue;

      ordinal += 1;
      final region = _mergeRegions(sourceFragments);
      rows.add(
        CurriculumDraftRow(
          candidateKey: 'candidate-p${line.page}-$ordinal',
          subjectIndex: subjectIndex,
          subjectName: subjectName,
          sourcePage: line.page,
          sourceRegion: region,
          rawText: rawParts.join('\n'),
          blockingIssues: const [
            'semester_required',
            'review_confirmation_required',
          ],
          warnings: [
            'Название извлечено как кандидат; проверьте по странице.',
            if (!hadNumericTail)
              'Граница названия не подтверждена колонками таблицы.',
          ],
        ),
      );
    }
    return rows;
  }

  List<CurriculumDraftRow> _parseCoordinateTable(
    AcademicTextPage page, {
    required int nominalSemesters,
  }) {
    if (!_hasSupportedTableHeader(page, nominalSemesters)) return const [];

    final anchors = page.fragments.where((fragment) {
      final centerX = _centerX(fragment) / page.width;
      return centerX < 0.04 &&
          _subjectIndexOnlyPattern.hasMatch(fragment.text.trim());
    }).toList()..sort((a, b) => _centerY(b).compareTo(_centerY(a)));
    if (anchors.isEmpty) return const [];

    final rows = <CurriculumDraftRow>[];
    for (var index = 0; index < anchors.length; index++) {
      final anchor = anchors[index];
      final anchorY = _centerY(anchor);
      final nextY = index + 1 < anchors.length
          ? _centerY(anchors[index + 1])
          : 0.0;
      final sectionBoundaryY = page.fragments
          .where((fragment) {
            final y = _centerY(fragment);
            final x = _centerX(fragment) / page.width;
            return y < anchorY &&
                y > nextY &&
                x < 0.04 &&
                _sectionBoundaryPattern.hasMatch(fragment.text.trim());
          })
          .map(_centerY)
          .fold<double?>(null, (current, y) {
            return current == null || y > current ? y : current;
          });
      final lowerY = sectionBoundaryY ?? nextY;
      final rowFragments = page.fragments.where((fragment) {
        final y = _centerY(fragment);
        return y <= anchorY + 2.5 && y > lowerY + 2.5;
      }).toList();
      final subjectIndex = anchor.text.trim();
      final nameFragments = rowFragments.where((fragment) {
        final x = _centerX(fragment) / page.width;
        final text = fragment.text.trim();
        return x >= 0.039 &&
            x < 0.102 &&
            text.isNotEmpty &&
            !_subjectIndexOnlyPattern.hasMatch(text);
      }).toList()..sort(_readingOrder);
      final subjectName = nameFragments
          .map((fragment) => fragment.text.trim())
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (subjectName.isEmpty) continue;

      final credits = _singleNumberInRange(
        rowFragments,
        page.width,
        0.163,
        0.174,
      );
      final hours = _singleNumberInRange(
        rowFragments,
        page.width,
        0.174,
        0.185,
      );
      final assessments = <CurriculumDraftAssessment>[];
      final unresolvedAssessments = <CurriculumDraftAssessment>[];
      final blockers = <String>[];
      for (final column in _assessmentColumns) {
        final cells = _fragmentsInRange(
          rowFragments,
          page.width,
          column.left,
          column.right,
        );
        for (final cell in cells) {
          final raw = cell.text.trim();
          if (raw.isEmpty || raw == '-') continue;
          final semesters = _decodeCompactSemesters(raw, nominalSemesters);
          if (semesters == null) {
            blockers.add(
              'assessment_semester_unresolved:${column.type.wire}:$raw',
            );
            unresolvedAssessments.add(
              CurriculumDraftAssessment(
                type: column.type,
                semesterNumber: null,
                rawValue: raw,
                sourcePage: page.page,
                sourceRegion: cell.region,
                warnings: const [
                  'Не удалось однозначно определить семестр формы контроля.',
                ],
              ),
            );
            continue;
          }
          for (final semester in semesters) {
            final duplicate = assessments.any(
              (assessment) =>
                  assessment.type == column.type &&
                  assessment.semesterNumber == semester,
            );
            if (duplicate) {
              blockers.add(
                'duplicate_assessment:${column.type.wire}:$semester',
              );
              continue;
            }
            assessments.add(
              CurriculumDraftAssessment(
                type: column.type,
                semesterNumber: semester,
                rawValue: raw,
                sourcePage: page.page,
                sourceRegion: cell.region,
              ),
            );
          }
        }
      }

      final occurrenceFragments = <int, List<AcademicTextFragment>>{};
      for (var semester = 1; semester <= nominalSemesters; semester++) {
        final range = _semesterRange(semester, nominalSemesters);
        final cells = _fragmentsInRange(
          rowFragments,
          page.width,
          range.$1,
          range.$2,
        ).where((fragment) => _parseNumber(fragment.text) != null).toList();
        if (cells.isNotEmpty) occurrenceFragments[semester] = cells;
      }
      for (final assessment in assessments) {
        final semester = assessment.semesterNumber;
        if (semester != null) {
          occurrenceFragments.putIfAbsent(semester, () => []);
        }
      }

      final occurrences = occurrenceFragments.entries.map((entry) {
        final semester = entry.key;
        final cells = entry.value;
        final range = _semesterRange(semester, nominalSemesters);
        final workload = <String, num>{};
        for (final cell in cells) {
          final value = _parseNumber(cell.text);
          if (value == null) continue;
          final relative =
              ((_centerX(cell) / page.width) - range.$1) /
              (range.$2 - range.$1);
          final slot = (relative * 10).floor().clamp(0, 9) + 1;
          workload['source_column_$slot'] = value;
        }
        final occurrenceAssessments = assessments
            .where((assessment) => assessment.semesterNumber == semester)
            .toList(growable: false);
        final evidence = <AcademicTextFragment>[
          ...cells,
          for (final assessment in occurrenceAssessments)
            if (assessment.sourceRegion != null)
              AcademicTextFragment(
                page: assessment.sourcePage,
                text: assessment.rawValue,
                region: assessment.sourceRegion!,
              ),
        ];
        return CurriculumDraftOccurrence(
          semesterNumber: semester,
          sourcePage: page.page,
          sourceRegion: _mergeRegions(evidence),
          workload: workload,
          assessments: occurrenceAssessments,
        );
      }).toList()..sort((a, b) => a.semesterNumber.compareTo(b.semesterNumber));

      rows.add(
        CurriculumDraftRow(
          candidateKey: 'candidate-p${page.page}-${rows.length + 1}',
          subjectIndex: subjectIndex,
          subjectName: subjectName,
          sourcePage: page.page,
          sourceRegion: _mergeRegions(rowFragments),
          hoursTotal: hours?.round(),
          credits: credits,
          occurrences: occurrences,
          unresolvedAssessments: unresolvedAssessments,
          rawText: (rowFragments..sort(_readingOrder))
              .map((fragment) => fragment.text.trim())
              .where((value) => value.isNotEmpty)
              .join(' '),
          blockingIssues: [
            if (occurrences.isEmpty) 'semester_required',
            ...blockers,
            'review_confirmation_required',
          ],
          warnings: const [
            'Семестры, нагрузка и формы контроля извлечены по координатам таблицы.',
          ],
        ),
      );
    }
    return rows;
  }

  bool _hasSupportedTableHeader(AcademicTextPage page, int nominalSemesters) {
    final text = page.fullText.replaceAll(RegExp(r'\s+'), ' ');
    const required = [
      'Индекс',
      'Наименование',
      'Экза',
      'Зачет',
      'КП',
      'КР',
      'Контр.',
      'Итого',
      'акад.часов',
    ];
    if (required.any((header) => !text.contains(header))) return false;
    for (var semester = 1; semester <= nominalSemesters; semester++) {
      if (!RegExp(
        'Семестр\\s+$semester',
        caseSensitive: false,
      ).hasMatch(text)) {
        return false;
      }
    }
    return true;
  }

  List<AcademicTextFragment> _fragmentsInRange(
    List<AcademicTextFragment> fragments,
    double width,
    double left,
    double right,
  ) {
    return fragments
        .where((fragment) {
          final x = _centerX(fragment) / width;
          return x >= left && x < right;
        })
        .toList(growable: false);
  }

  num? _singleNumberInRange(
    List<AcademicTextFragment> fragments,
    double width,
    double left,
    double right,
  ) {
    final values = _fragmentsInRange(
      fragments,
      width,
      left,
      right,
    ).map((fragment) => _parseNumber(fragment.text)).whereType<num>();
    return values.length == 1 ? values.single : null;
  }

  List<int>? _decodeCompactSemesters(String raw, int nominalSemesters) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), '');
    if (!RegExp(r'^\d+$').hasMatch(normalized)) return null;
    final exact = int.parse(normalized);
    // A zero cannot represent a one-digit semester, so "10" is the
    // unambiguous marker for semester 10. Other multi-digit values such as
    // "12" remain compact semester lists (1 and 2) instead of being guessed.
    if (normalized.contains('0') && exact >= 10 && exact <= nominalSemesters) {
      return [exact];
    }
    final values = normalized.split('').map(int.parse).toList(growable: false);
    if (values.any((value) => value < 1 || value > nominalSemesters)) {
      return null;
    }
    return values.toSet().toList(growable: false);
  }

  (double, double) _semesterRange(int semester, int total) {
    if (total == 8) return _pgsSemesterRanges[semester - 1];
    const left = 0.229;
    const right = 0.932;
    final width = (right - left) / total;
    return (left + (semester - 1) * width, left + semester * width);
  }

  num? _parseNumber(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    return num.tryParse(normalized);
  }

  double _centerX(AcademicTextFragment fragment) =>
      (fragment.region.left + fragment.region.right) / 2;

  double _centerY(AcademicTextFragment fragment) =>
      (fragment.region.top + fragment.region.bottom) / 2;

  int _readingOrder(AcademicTextFragment a, AcademicTextFragment b) {
    final y = _centerY(b).compareTo(_centerY(a));
    return y == 0 ? a.region.left.compareTo(b.region.left) : y;
  }

  AcademicSourceRegion? _mergeRegions(List<AcademicTextFragment> fragments) {
    if (fragments.isEmpty) return null;
    var left = fragments.first.region.left;
    var top = fragments.first.region.top;
    var right = fragments.first.region.right;
    var bottom = fragments.first.region.bottom;
    for (final fragment in fragments.skip(1)) {
      final region = fragment.region;
      if (region.left < left) left = region.left;
      if (region.top > top) top = region.top;
      if (region.right > right) right = region.right;
      if (region.bottom < bottom) bottom = region.bottom;
    }
    return AcademicSourceRegion(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  String _stripNumericTail(String value) {
    final tokens = value.split(RegExp(r'\s+'));
    for (var index = 0; index < tokens.length; index++) {
      if (!_numericToken.hasMatch(tokens[index])) continue;
      if (index > 0 &&
          RegExp(
            r'^(часть|модуль)$',
            caseSensitive: false,
          ).hasMatch(tokens[index - 1])) {
        continue;
      }
      final numericAhead = tokens
          .skip(index)
          .take(5)
          .where(_numericToken.hasMatch)
          .length;
      if (numericAhead >= 2) {
        return tokens.take(index).join(' ').trim();
      }
    }
    return value.trim();
  }

  bool _looksLikeNameContinuation(String value) {
    if (value.isEmpty || value.length > 160) return false;
    if (RegExp(
      r'^(Блок|Обязательная|Часть,)',
      caseSensitive: false,
    ).hasMatch(value)) {
      return false;
    }
    return RegExp(r'[А-Яа-яЁё]').hasMatch(value);
  }

  String? _directionName(String source, String? directionCode) {
    if (directionCode == null) return null;
    final match = RegExp('${RegExp.escape(directionCode)}\\s+([^\\n]+)')
        .allMatches(source)
        .where((candidate) {
          final value = (candidate.group(1) ?? '').trim();
          return value.isNotEmpty && !value.startsWith(directionCode);
        })
        .firstOrNull;
    return match?.group(1)?.trim();
  }

  String? _directionNameFromLayout(
    List<AcademicTextPage> pages,
    String? directionCode,
  ) {
    if (directionCode == null) return null;
    for (final page in pages) {
      final codeFragments = page.fragments.where(
        (fragment) => fragment.text.trim() == directionCode,
      );
      for (final code in codeFragments) {
        final codeY = (code.region.top + code.region.bottom) / 2;
        final candidates = page.fragments.where((fragment) {
          final text = fragment.text.trim();
          final y = (fragment.region.top + fragment.region.bottom) / 2;
          return fragment.region.left >= code.region.right - 2 &&
              (y - codeY).abs() <= 4 &&
              text.length >= 3 &&
              text.length <= 100 &&
              RegExp(r'^[А-ЯЁ][А-Яа-яЁё -]+$').hasMatch(text);
        }).toList()..sort((a, b) => a.region.left.compareTo(b.region.left));
        if (candidates.isNotEmpty) return candidates.first.text.trim();
      }
    }
    return null;
  }

  String? _profileNameFromLayout(List<AcademicTextPage> pages) {
    for (final page in pages) {
      for (final label in page.fragments.where(
        (fragment) => fragment.text.toLowerCase().contains('направленность'),
      )) {
        final labelY = (label.region.top + label.region.bottom) / 2;
        final candidates = page.fragments.where((fragment) {
          final text = fragment.text.trim();
          final y = (fragment.region.top + fragment.region.bottom) / 2;
          return fragment.region.left >= label.region.right - 2 &&
              fragment.region.left < page.width * 0.45 &&
              (y - labelY).abs() <= 4 &&
              text.isNotEmpty &&
              !text.toLowerCase().contains('профиль') &&
              RegExp(r'^[А-Яа-яЁё -]+$').hasMatch(text);
        }).toList()..sort((a, b) => a.region.left.compareTo(b.region.left));
        final value = candidates
            .map((fragment) => fragment.text.trim())
            .join(' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (value.length >= 5) return value;
      }
    }
    return null;
  }

  bool _validProfileName(String? value) {
    if (value == null || value.length < 5 || value.endsWith(':')) return false;
    final normalized = value.toLowerCase();
    return !normalized.startsWith('кафедра') &&
        !normalized.startsWith('факультет') &&
        !normalized.startsWith('типы задач');
  }

  AcademicStudyForm? _studyForm(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == null) return null;
    if (value.startsWith('очно-заоч')) return AcademicStudyForm.partTime;
    if (value.startsWith('заоч')) return AcademicStudyForm.extramural;
    if (value.startsWith('очн')) return AcademicStudyForm.fullTime;
    if (value.startsWith('смеш')) return AcademicStudyForm.mixed;
    return null;
  }

  String? _firstGroup(String source, RegExp pattern) {
    final value = pattern.firstMatch(source)?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

class ParsedCurriculumDocument {
  const ParsedCurriculumDocument({
    required this.metadata,
    required this.rows,
    required this.characterCount,
  });

  final CurriculumDraftMetadata metadata;
  final List<CurriculumDraftRow> rows;
  final int characterCount;
}

class _LayoutLine {
  _LayoutLine({
    required this.page,
    required this.centerY,
    required this.fragments,
  });

  final int page;
  final double centerY;
  final List<AcademicTextFragment> fragments;

  String get text => fragments
      .map((fragment) => fragment.text.trim())
      .where((value) => value.isNotEmpty)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

final _subjectIndexPattern = RegExp(
  r'^\s*((?:Б[123](?:\.[А-ЯA-Z0-9()]+)+|ФТД(?:\.[А-ЯA-Z0-9()]+)+))\s+(.+)$',
);

final _subjectIndexOnlyPattern = RegExp(
  r'^(?:Б[123](?:\.[А-ЯA-Z0-9()]+)+|ФТД(?:\.[А-ЯA-Z0-9()]+)+)$',
);

final _sectionBoundaryPattern = RegExp(
  r'^(?:Блок\b|Обязательная\b|Часть,|ФТД\.Факультативные\b)',
  caseSensitive: false,
);

const _assessmentColumns = [
  _AssessmentColumn(0.102, 0.112, CurriculumAssessmentType.exam),
  _AssessmentColumn(0.112, 0.122, CurriculumAssessmentType.credit),
  _AssessmentColumn(0.122, 0.1325, CurriculumAssessmentType.gradedCredit),
  _AssessmentColumn(0.1325, 0.1425, CurriculumAssessmentType.courseProject),
  _AssessmentColumn(0.1425, 0.152, CurriculumAssessmentType.courseWork),
  _AssessmentColumn(0.152, 0.163, CurriculumAssessmentType.controlWork),
];

const _pgsSemesterRanges = [
  (0.229, 0.322),
  (0.322, 0.411),
  (0.411, 0.501),
  (0.501, 0.591),
  (0.591, 0.672),
  (0.672, 0.762),
  (0.762, 0.842),
  (0.842, 0.932),
];

class _AssessmentColumn {
  const _AssessmentColumn(this.left, this.right, this.type);

  final double left;
  final double right;
  final CurriculumAssessmentType type;
}

final _numericToken = RegExp(r'^\d+(?:[.,]\d+)?$');

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
