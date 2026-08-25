/// Admission-year rules for student-sourced groups.
///
/// The usual year comes from the selected academic year and the course in the
/// group name: `startYear - course + 1`. A record book / login that starts with
/// `26` usually confirms admission 2026. The rare case — admitted onto course 2
/// in the current year — must not be merged into the other cohort.
class StudentImportGroupResolution {
  const StudentImportGroupResolution({
    required this.ok,
    this.error,
    this.normalizedGroupName,
    this.parallelNumber,
    this.courseNumber,
    this.derivedAdmissionYear,
    this.recordBookAdmissionYear,
    this.admissionYear,
    this.willCreate = false,
    this.groupAction,
    this.warnings = const [],
    this.cacheKey,
  });

  final bool ok;
  final String? error;
  final String? normalizedGroupName;
  final int? parallelNumber;
  final int? courseNumber;
  final int? derivedAdmissionYear;
  final int? recordBookAdmissionYear;
  final int? admissionYear;
  final bool willCreate;
  final String? groupAction;
  final List<String> warnings;
  final String? cacheKey;
}

final _groupNamePattern = RegExp(r'^([1-9][0-9]*)-([^-]+)-([1-9][0-9]*)$');
final _recordBookPattern = RegExp(r'^([0-9]{2})[-./]?[0-9]');

String? normalizeStudentImportGroupName(String? raw) {
  if (raw == null) return null;
  final compact = raw
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[‐‑‒–—−]'), '-')
      .replaceAll(RegExp(r'[\s()]'), '');
  return compact.isEmpty ? null : compact;
}

int? studentImportRecordBookYear(String? login) {
  final match = _recordBookPattern.firstMatch(
    (login ?? '').trim().toLowerCase(),
  );
  if (match == null) return null;
  final year = 2000 + int.parse(match.group(1)!);
  if (year < 2000 || year > 2100) return null;
  return year;
}

StudentImportGroupResolution resolveStudentImportGroup({
  required int academicYearStart,
  required String groupName,
  required String login,
}) {
  final nameKey = normalizeStudentImportGroupName(groupName);
  if (nameKey == null) {
    return const StudentImportGroupResolution(ok: true, willCreate: false);
  }

  final parsed = _groupNamePattern.firstMatch(nameKey);
  if (parsed == null) {
    return StudentImportGroupResolution(
      ok: false,
      error: 'group_name_shape_unrecognized',
      normalizedGroupName: nameKey,
      recordBookAdmissionYear: studentImportRecordBookYear(login),
      warnings: const ['group_name_shape_unrecognized'],
    );
  }

  final parallel = int.parse(parsed.group(1)!);
  final programKey = parsed.group(2)!;
  final course = int.parse(parsed.group(3)!);
  final derived = academicYearStart - course + 1;
  final recordBook = studentImportRecordBookYear(login);
  final warnings = <String>[];

  if (recordBook == null) {
    warnings.add('record_book_year_absent');
  } else if (recordBook != derived) {
    return StudentImportGroupResolution(
      ok: false,
      error: 'record_book_admission_mismatch',
      normalizedGroupName: nameKey,
      parallelNumber: parallel,
      courseNumber: course,
      derivedAdmissionYear: derived,
      recordBookAdmissionYear: recordBook,
      warnings: const ['record_book_admission_mismatch'],
    );
  }

  return StudentImportGroupResolution(
    ok: true,
    normalizedGroupName: nameKey,
    parallelNumber: parallel,
    courseNumber: course,
    derivedAdmissionYear: derived,
    recordBookAdmissionYear: recordBook,
    admissionYear: derived,
    willCreate: true,
    groupAction: 'create',
    warnings: warnings,
    cacheKey: '$programKey:$derived:$parallel:$nameKey',
  );
}

String studentImportErrorLabel(String? code) {
  return switch (code) {
    'login_required' => 'Нужен логин / номер зачётной книжки.',
    'duplicate_in_file' => 'Этот логин повторяется в файле.',
    'auth_user_missing' =>
      'Такого пользователя ещё нет. Новые аккаунты здесь не создаются.',
    'not_a_student' => 'Этот логин есть, но это не студент.',
    'academic_year_required' =>
      'Выберите учебный год: одно и то же название группы бывает у разных годов поступления.',
    'academic_year_not_found' => 'Выбранный учебный год не найден.',
    'group_name_shape_unrecognized' =>
      'Название группы не распознано. Нужен вид вроде 1-СбПГС-2.',
    'group_name_contains_unapproved_punctuation' =>
      'В названии группы есть символы, которые нельзя нормализовать автоматически.',
    'program_alias_not_reviewed' =>
      'Код программы в названии группы ещё не проверен.',
    'educational_program_not_active' =>
      'Программа в названии группы неактивна.',
    'matching_reviewed_plan_not_found' =>
      'Нет проверенного учебного плана для этого года поступления.',
    'multiple_plan_versions_require_choice' =>
      'Для этого года поступления есть несколько планов — выберите план отдельно.',
    'record_book_admission_mismatch' =>
      'Зачётка начинается с одного года, а курс в названии группы указывает другой. Так бывает при поступлении сразу на 2 курс — строку нельзя смешать с основной группой другого года.',
    'group_admission_year_conflict' =>
      'Группа с таким названием уже есть у другого года поступления.',
    'group_identity_missing' =>
      'Группа с таким названием есть, но год поступления у неё ещё не зафиксирован.',
    'group_alias_collision' =>
      'Одно название группы указывает на несколько групп.',
    'group_identity_collision' =>
      'Для этой программы, года и параллели найдено несколько групп.',
    'groups_write_required' =>
      'Чтобы группа появилась из студента, нужны права на группы.',
    _ => code ?? '',
  };
}
