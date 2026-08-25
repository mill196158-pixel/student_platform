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

    final candidateRows = _parseCandidateRows(lines);
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

final _numericToken = RegExp(r'^\d+(?:[.,]\d+)?$');

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
