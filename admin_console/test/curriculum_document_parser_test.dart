import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_document_draft.dart';
import 'package:student_platform_admin/features/import_studio/curriculum_document_parser.dart';

void main() {
  const parser = CurriculumDocumentParser();

  test('extracts plan metadata and conservative subject candidates', () {
    const fullText = '''
Квалификация: бакалавр Год начала подготовки (по учебному плану) 2025
Срок получения образования: 4 г.
Форма обучения: Очная
08.03.01 Строительство
направленность (профиль) : Промышленное и гражданское строительство, год начала подготовки 2025
Семестр 1 Семестр 2 Семестр 3 Семестр 4
Семестр 5 Семестр 6 Семестр 7 Семестр 8
План Учебный план бакалавриата '08.03.01_2025_2_ПГС.plx'
Б1.О.01 Физическая культура и спорт 5 2 72 32 36 4
Б1.О.12 Экономическая грамотность в условиях
цифровой трансформации 1 2 72 32 36 4
''';
    final page = AcademicTextPage(
      page: 1,
      width: 1200,
      height: 800,
      fullText: fullText,
      fragments: const [
        AcademicTextFragment(
          page: 1,
          text: 'Б1.О.01 Физическая культура и спорт 5 2 72 32 36 4',
          region: AcademicSourceRegion(
            left: 10,
            top: 500,
            right: 900,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 1,
          text: 'Б1.О.12 Экономическая грамотность в условиях',
          region: AcademicSourceRegion(
            left: 10,
            top: 480,
            right: 420,
            bottom: 470,
          ),
        ),
        AcademicTextFragment(
          page: 1,
          text: 'цифровой трансформации 1 2 72 32 36 4',
          region: AcademicSourceRegion(
            left: 120,
            top: 468,
            right: 900,
            bottom: 458,
          ),
        ),
      ],
    );

    final result = parser.parsePdfPages([page]);

    expect(result.metadata.directionCode, '08.03.01');
    expect(result.metadata.directionName, 'Строительство');
    expect(
      result.metadata.profileName,
      'Промышленное и гражданское строительство',
    );
    expect(result.metadata.qualification, 'бакалавр');
    expect(result.metadata.studyForm, AcademicStudyForm.fullTime);
    expect(result.metadata.admissionYear, 2025);
    expect(result.metadata.nominalSemesters, 8);
    expect(result.metadata.durationYears, 4);
    expect(result.metadata.planCode, '08.03.01_2025_2_ПГС.plx');
    expect(result.rows, hasLength(2));
    expect(result.rows.first.subjectIndex, 'Б1.О.01');
    expect(result.rows.first.subjectName, 'Физическая культура и спорт');
    expect(
      result.rows[1].subjectName,
      'Экономическая грамотность в условиях цифровой трансформации',
    );
    expect(result.rows[1].rawText, contains('цифровой трансформации'));
    expect(result.rows[1].sourceRegion?.top, 480);
    expect(result.rows[1].sourceRegion?.bottom, 458);
    expect(result.rows.every((row) => row.occurrences.isEmpty), isTrue);
    expect(result.rows.every((row) => row.requiresReview), isTrue);
  });

  test('marks elective aggregate parent as blocking review decision', () {
    final result = parser.parsePdfPages([
      const AcademicTextPage(
        page: 1,
        width: 1000,
        height: 700,
        fullText:
            'Б1.В.ДВ.02 Элективные дисциплины\n'
            'Б1.В.ДВ.02.01 Методы проектирования 7 3 108',
        fragments: [
          AcademicTextFragment(
            page: 1,
            text: 'Б1.В.ДВ.02 Элективные дисциплины',
            region: AcademicSourceRegion(
              left: 10,
              top: 300,
              right: 400,
              bottom: 290,
            ),
          ),
          AcademicTextFragment(
            page: 1,
            text: 'Б1.В.ДВ.02.01 Методы проектирования 7 3 108',
            region: AcademicSourceRegion(
              left: 10,
              top: 280,
              right: 600,
              bottom: 270,
            ),
          ),
        ],
      ),
    ]);

    expect(result.rows, hasLength(2));
    expect(
      result.rows.first.blockingIssues,
      contains('aggregate_parent_decision_required'),
    );
  });

  test('maps coordinate columns to occurrences and typed controls', () {
    const page = AcademicTextPage(
      page: 2,
      width: 1000,
      height: 700,
      fullText:
          'Индекс Наименование Экзамен Зачет Зачет с оц. КП КР Контр. '
          'Итого акад.часов Семестр 1 Семестр 2 Семестр 3 Семестр 4 '
          'Семестр 5 Семестр 6 Семестр 7 Семестр 8',
      fragments: [
        AcademicTextFragment(
          page: 2,
          text: 'Б1.О.01',
          region: AcademicSourceRegion(
            left: 15,
            top: 500,
            right: 30,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 2,
          text: 'Физическая культура и спорт',
          region: AcademicSourceRegion(
            left: 45,
            top: 500,
            right: 100,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 2,
          text: '5',
          region: AcademicSourceRegion(
            left: 114,
            top: 500,
            right: 119,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 2,
          text: 'X',
          region: AcademicSourceRegion(
            left: 103,
            top: 500,
            right: 107,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 2,
          text: '2',
          region: AcademicSourceRegion(
            left: 165,
            top: 500,
            right: 170,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 2,
          text: '72',
          region: AcademicSourceRegion(
            left: 176,
            top: 500,
            right: 182,
            bottom: 490,
          ),
        ),
        AcademicTextFragment(
          page: 2,
          text: '36',
          region: AcademicSourceRegion(
            left: 600,
            top: 500,
            right: 608,
            bottom: 490,
          ),
        ),
      ],
    );

    final row = parser.parsePdfPages([page]).rows.single;

    expect(row.credits, 2);
    expect(row.hoursTotal, 72);
    expect(row.occurrences.map((value) => value.semesterNumber), [5]);
    expect(
      row.occurrences.single.assessments.single.type,
      CurriculumAssessmentType.credit,
    );
    expect(row.occurrences.single.assessments.single.semesterNumber, 5);
    expect(
      row.unresolvedAssessments.single.type,
      CurriculumAssessmentType.exam,
    );
    expect(
      row.blockingIssues,
      contains('assessment_semester_unresolved:exam:X'),
    );
  });

  test('keeps semester 10 as one assessment semester', () {
    final headers = [
      for (var semester = 1; semester <= 10; semester++) 'Семестр $semester',
    ].join(' ');
    final row = parser
        .parsePdfPages([
          AcademicTextPage(
            page: 1,
            width: 1000,
            height: 700,
            fullText:
                'Индекс Наименование Экзамен Зачет Зачет с оц. КП КР '
                'Контр. Итого акад.часов $headers',
            fragments: const [
              AcademicTextFragment(
                page: 1,
                text: 'Б1.О.10',
                region: AcademicSourceRegion(
                  left: 15,
                  top: 500,
                  right: 30,
                  bottom: 490,
                ),
              ),
              AcademicTextFragment(
                page: 1,
                text: 'Дисциплина десятого семестра',
                region: AcademicSourceRegion(
                  left: 45,
                  top: 500,
                  right: 100,
                  bottom: 490,
                ),
              ),
              AcademicTextFragment(
                page: 1,
                text: '10',
                region: AcademicSourceRegion(
                  left: 103,
                  top: 500,
                  right: 108,
                  bottom: 490,
                ),
              ),
            ],
          ),
        ])
        .rows
        .single;

    expect(row.occurrences.map((value) => value.semesterNumber), [10]);
    expect(
      row.occurrences.single.assessments.single.type,
      CurriculumAssessmentType.exam,
    );
    expect(row.unresolvedAssessments, isEmpty);
  });
}
