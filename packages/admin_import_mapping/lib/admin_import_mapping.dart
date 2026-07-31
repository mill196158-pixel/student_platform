library admin_import_mapping;

String normalizePersonName(String value) {
  return value
      .replaceAll('\u00a0', ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
}

class ImportColumnMapping {
  const ImportColumnMapping({
    required this.header,
    required this.field,
    required this.index,
  });

  final String header;
  final String field;
  final int index;
}

enum TeacherImportClassification { newTeacher, update, duplicate, error }

TeacherImportClassification classifyTeacherRow({
  required Map<String, Object?> row,
  required Iterable<String> existingNormalizedNames,
  Iterable<String> seenNormalizedNames = const [],
}) {
  final name = normalizePersonName('${row['full_name'] ?? ''}');
  if (name.isEmpty) return TeacherImportClassification.error;
  if (seenNormalizedNames.map(normalizePersonName).contains(name)) {
    return TeacherImportClassification.duplicate;
  }
  return existingNormalizedNames.map(normalizePersonName).contains(name)
      ? TeacherImportClassification.update
      : TeacherImportClassification.newTeacher;
}

/// Suggested field → source header. First matching alias wins per field.
Map<String, String> suggestHeaderMapping(List<String> headers) {
  const aliases = <String, List<String>>{
    'teacher_id': ['teacher_id', 'id', 'uuid'],
    'full_name': ['фио', 'ф.и.о.', 'преподаватель', 'full name', 'name'],
    'department': ['кафедра', 'department'],
    'position': ['должность', 'position'],
    'academic_degree': ['ученая степень', 'учёная степень', 'degree'],
    'about_text': ['о преподавателе', 'about', 'описание'],
    'public_email': ['email', 'e-mail', 'почта', 'public_email'],
    'website': ['сайт', 'website', 'url'],
    'office': ['кабинет', 'office'],
    'telegram': ['telegram', 'телеграм'],
  };
  final byField = <String, String>{};
  for (var index = 0; index < headers.length; index++) {
    final header = headers[index];
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

List<ImportColumnMapping> suggestHeaderMappingList(List<String> headers) {
  final map = suggestHeaderMapping(headers);
  return [
    for (final entry in map.entries)
      ImportColumnMapping(
        header: entry.value,
        field: entry.key,
        index: headers.indexOf(entry.value),
      ),
  ];
}

/// Applies field→header mapping to a raw sheet row.
Map<String, dynamic> mapImportRow(
  Map<String, String> raw,
  Map<String, String> fieldToHeader,
) {
  final mapped = <String, dynamic>{};
  fieldToHeader.forEach((field, header) {
    mapped[field] = raw[header] ?? '';
  });
  final contacts = <String, dynamic>{};
  for (final key in const ['website', 'public_email', 'office', 'telegram']) {
    final value = (mapped[key] ?? '').toString().trim();
    if (value.isNotEmpty) contacts[key] = value;
  }
  if (contacts.isNotEmpty) {
    mapped['contacts_public'] = contacts;
  }
  final linksRaw = (mapped['useful_links'] ?? '').toString().trim();
  if (linksRaw.isNotEmpty) {
    mapped['useful_links'] = parseUsefulLinks(linksRaw);
  }
  return mapped;
}

/// Parses `title|url` or bare URL lines into JSON-ready maps.
List<Map<String, String>> parseUsefulLinks(String raw) {
  final links = <Map<String, String>>[];
  for (final line in raw.split(RegExp(r'[\n;]+'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split('|');
    if (parts.length >= 2) {
      final title = parts.first.trim();
      final url = parts.sublist(1).join('|').trim();
      if (url.isEmpty) continue;
      links.add({'title': title.isEmpty ? url : title, 'url': url});
    } else {
      links.add({'title': trimmed, 'url': trimmed});
    }
  }
  return links;
}

/// Suggested field → source header for student spreadsheets.
Map<String, String> suggestStudentHeaderMapping(List<String> headers) {
  const aliases = <String, List<String>>{
    'login': ['логин', 'login', 'username', 'студбилет', 'номер'],
    'name': ['имя', 'name', 'first_name'],
    'surname': ['фамилия', 'surname', 'last_name'],
    'group_name': ['группа', 'group', 'group_name'],
  };
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

/// Suggested field → source header for subject spreadsheets.
Map<String, String> suggestSubjectHeaderMapping(List<String> headers) {
  const aliases = <String, List<String>>{
    'subject_id': ['subject_id', 'id', 'uuid'],
    'canonical_name': [
      'предмет',
      'название',
      'дисциплина',
      'subject',
      'canonical_name',
      'name',
    ],
    'department': ['кафедра', 'department'],
    'control_form': ['форма контроля', 'контроль', 'control_form', 'exam'],
    'difficulty_label': ['сложность', 'difficulty'],
    'description': ['описание', 'description'],
    'short_description': ['краткое описание', 'short_description'],
    'learning_outcomes': ['чему научится', 'результаты', 'learning_outcomes'],
    'requirements': ['требования', 'requirements'],
    'what_to_expect': ['чего ожидать', 'what_to_expect'],
    'how_to_pass': ['как сдать', 'how_to_pass'],
    'useful_materials_note': ['материалы', 'materials'],
    'useful_links': ['ссылки', 'links', 'полезные ссылки', 'useful_links'],
    'common_pitfalls': ['ошибки', 'pitfalls'],
  };
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
