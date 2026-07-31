import 'package:admin_import_mapping/admin_import_mapping.dart';

/// Suggested field → spreadsheet header for a domain.
Map<String, String> suggestImportStudioHeaderMapping(
  String domain,
  List<String> headers,
) {
  return switch (domain) {
    'teachers' => suggestHeaderMapping(headers),
    'subjects' => suggestSubjectHeaderMapping(headers),
    'students' => suggestStudentHeaderMapping(headers),
    'groups' => _suggestSimpleMapping(headers, const {
      'name': ['группа', 'group', 'name', 'название'],
    }),
    'curriculum' => _suggestSimpleMapping(headers, const {
      'group_name': ['группа', 'group'],
      'subject_name': ['предмет', 'subject', 'дисциплина'],
      'semester_number': ['семестр', 'semester'],
      'credits': ['зачётные', 'credits', 'з.e.'],
      'hours_total': ['часы', 'hours'],
      'control_form': ['форма контроля', 'контроль', 'control_form'],
      'block_name': ['блок', 'block'],
      'subject_index': ['индекс', 'index'],
    }),
    'terms' => _suggestSimpleMapping(headers, const {
      'academic_year_name': ['учебный год', 'academic year', 'year'],
      'name': ['семестр', 'term', 'name'],
      'term_in_year': ['номер', 'term_in_year', 'semester number'],
      'starts_on': ['начало', 'starts', 'start'],
      'ends_on': ['окончание', 'ends', 'end'],
    }),
    'offerings' => _suggestSimpleMapping(headers, const {
      'group_name': ['группа', 'group'],
      'subject_name': ['предмет', 'subject', 'дисциплина'],
      'academic_year_name': ['учебный год', 'academic year', 'year'],
      'term_name': ['семестр', 'term'],
      'semester_number': ['номер семестра', 'semester_number'],
      'display_name': ['название', 'display_name'],
      'status': ['статус', 'status'],
    }),
    'teacher_links' => _suggestSimpleMapping(headers, const {
      'group_name': ['группа', 'group'],
      'subject_name': ['предмет', 'subject', 'дисциплина'],
      'academic_year_name': ['учебный год', 'academic year', 'year'],
      'term_name': ['семестр', 'term'],
      'teacher_full_name': ['преподаватель', 'фио преподавателя', 'teacher'],
      'role': ['роль', 'role'],
    }),
    'enrollments' => _suggestSimpleMapping(headers, const {
      'login': ['логин', 'login'],
      'group_name': ['группа', 'group'],
      'started_at': ['дата начала', 'started_at', 'start date'],
    }),
    _ => const {},
  };
}

Map<String, String> _suggestSimpleMapping(
  List<String> headers,
  Map<String, List<String>> aliases,
) {
  final byField = <String, String>{};
  for (final header in headers) {
    final normalized = normalizePersonName(header);
    for (final entry in aliases.entries) {
      if (byField.containsKey(entry.key)) continue;
      if (entry.value.map(normalizePersonName).contains(normalized)) {
        byField[entry.key] = header;
        break;
      }
    }
  }
  return byField;
}

/// Applies column mapping and normalizes rows to the delegated Stage 13 contracts.
List<Map<String, dynamic>> mapImportStudioRows({
  required String domain,
  required List<Map<String, String>> rawRows,
  required Map<String, String> fieldToHeader,
}) {
  return [
    for (final raw in rawRows) _mapImportStudioRow(domain, raw, fieldToHeader),
  ];
}

Map<String, dynamic> _mapImportStudioRow(
  String domain,
  Map<String, String> raw,
  Map<String, String> fieldToHeader,
) {
  switch (domain) {
    case 'teachers':
    case 'subjects':
    case 'students':
      return mapImportRow(raw, fieldToHeader);
    default:
      final mapped = <String, dynamic>{};
      fieldToHeader.forEach((field, header) {
        mapped[field] = raw[header] ?? '';
      });
      return mapped;
  }
}

/// Field labels for the mapping dialog.
Map<String, String> importStudioMappingFieldLabels(String domain) {
  return switch (domain) {
    'teachers' => const {
      'teacher_id': 'ID преподавателя',
      'full_name': 'ФИО',
      'department': 'Кафедра',
      'position': 'Должность',
      'academic_degree': 'Учёная степень',
      'about_text': 'Описание',
      'public_email': 'Публичный email',
      'website': 'Сайт',
      'office': 'Кабинет',
      'telegram': 'Telegram',
    },
    'subjects' => const {
      'subject_id': 'ID предмета',
      'canonical_name': 'Название',
      'department': 'Кафедра',
      'control_form': 'Форма контроля',
      'difficulty_label': 'Сложность',
      'description': 'Описание',
      'short_description': 'Краткое описание',
      'learning_outcomes': 'Чему научится',
      'requirements': 'Требования',
      'what_to_expect': 'Чего ожидать',
      'how_to_pass': 'Как сдать',
      'useful_materials_note': 'Материалы',
      'useful_links': 'Полезные ссылки',
      'common_pitfalls': 'Типичные ошибки',
    },
    'students' => const {
      'login': 'Логин',
      'name': 'Имя',
      'surname': 'Фамилия',
      'group_name': 'Группа',
    },
    'groups' => const {
      'group_id': 'ID группы (для обновления)',
      'name': 'Название группы',
    },
    'curriculum' => const {
      'curriculum_subject_id': 'ID записи плана (для обновления)',
      'group_name': 'Группа',
      'subject_name': 'Предмет',
      'semester_number': 'Семестр',
      'credits': 'Зачётные единицы',
      'hours_total': 'Часы',
      'control_form': 'Форма контроля',
      'block_name': 'Блок',
      'subject_index': 'Индекс',
    },
    'terms' => const {
      'term_id': 'ID семестра (для обновления)',
      'academic_year_name': 'Учебный год',
      'name': 'Название семестра',
      'term_in_year': 'Номер в году',
      'starts_on': 'Дата начала',
      'ends_on': 'Дата окончания',
    },
    'offerings' => const {
      'offering_id': 'ID нагрузки (для обновления)',
      'group_name': 'Группа',
      'subject_name': 'Предмет',
      'academic_year_name': 'Учебный год',
      'term_name': 'Семестр',
      'semester_number': 'Номер семестра',
      'display_name': 'Название',
      'status': 'Статус',
    },
    'teacher_links' => const {
      'teacher_link_id': 'ID связи (для обновления)',
      'offering_id': 'ID нагрузки',
      'group_name': 'Группа',
      'subject_name': 'Предмет',
      'academic_year_name': 'Учебный год',
      'term_name': 'Семестр',
      'teacher_id': 'ID преподавателя',
      'teacher_full_name': 'ФИО преподавателя',
      'role': 'Роль',
    },
    'enrollments' => const {
      'enrollment_id': 'ID зачисления (для повтора)',
      'login': 'Логин студента',
      'group_name': 'Группа',
      'started_at': 'Дата начала',
    },
    _ => const {},
  };
}

/// Required mapped field for a domain (must be mapped before dry-run).
String? importStudioRequiredMappingField(String domain) {
  return switch (domain) {
    'teachers' => 'full_name',
    'subjects' => 'canonical_name',
    'students' => 'login',
    'groups' => 'name',
    'curriculum' => 'group_name',
    'terms' => 'name',
    'offerings' => 'group_name',
    'teacher_links' => 'teacher_full_name',
    'enrollments' => 'login',
    _ => null,
  };
}

/// Parses demo/sample CSV using template wire column names.
List<Map<String, dynamic>> parseImportStudioSampleCsv(
  String domain,
  String raw,
) {
  final lines = raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length < 2) return const [];

  final headers = lines.first.split(',').map((e) => e.trim()).toList();
  final rows = <Map<String, dynamic>>[];
  for (var i = 1; i < lines.length; i++) {
    final values = lines[i].split(',');
    final row = <String, dynamic>{};
    for (var j = 0; j < headers.length; j++) {
      row[headers[j]] = j < values.length ? values[j].trim() : '';
    }
    rows.add(_normalizeSampleRow(domain, row));
  }
  return rows;
}

Map<String, dynamic> _normalizeSampleRow(
  String domain,
  Map<String, dynamic> row,
) {
  if (domain != 'teachers') return row;

  final email = (row.remove('email') ?? '').toString().trim();
  if (email.isEmpty) return row;

  final contacts = <String, dynamic>{
    if (email.isNotEmpty) 'public_email': email,
  };
  row['contacts_public'] = contacts;
  return row;
}
