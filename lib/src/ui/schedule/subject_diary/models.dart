part of subject_diary;

/// ===== МОДЕЛИ

class SubjectDiaryArgs {
  final String? subjectOfferingId;
  final String? subjectId;
  final String subjectTitle;
  final String? groupId;
  final int? semesterNumber;
  final String? lessonId;
  final DateTime? date;
  final String? legacySubjectKey;

  const SubjectDiaryArgs({
    this.subjectOfferingId,
    this.subjectId,
    required this.subjectTitle,
    this.groupId,
    this.semesterNumber,
    this.lessonId,
    this.date,
    this.legacySubjectKey,
  });

  factory SubjectDiaryArgs.legacy(String subjectKey) {
    return SubjectDiaryArgs(
      subjectTitle: subjectKey,
      legacySubjectKey: subjectKey,
    );
  }

  bool get hasSubjectOffering =>
      (subjectOfferingId ?? '').trim().isNotEmpty;

  String get displayTitle {
    final title = subjectTitle.trim();
    if (title.isNotEmpty) return title;
    final legacy = (legacySubjectKey ?? '').trim();
    return legacy.isEmpty ? 'Предмет' : legacy;
  }

  String get fallbackSubjectKey {
    final legacy = (legacySubjectKey ?? '').trim();
    return legacy.isEmpty ? displayTitle : legacy;
  }

  SubjectDiaryArgs copyWith({
    String? subjectOfferingId,
    String? subjectId,
    String? subjectTitle,
    String? groupId,
    int? semesterNumber,
    String? lessonId,
    DateTime? date,
    String? legacySubjectKey,
  }) {
    return SubjectDiaryArgs(
      subjectOfferingId: subjectOfferingId ?? this.subjectOfferingId,
      subjectId: subjectId ?? this.subjectId,
      subjectTitle: subjectTitle ?? this.subjectTitle,
      groupId: groupId ?? this.groupId,
      semesterNumber: semesterNumber ?? this.semesterNumber,
      lessonId: lessonId ?? this.lessonId,
      date: date ?? this.date,
      legacySubjectKey: legacySubjectKey ?? this.legacySubjectKey,
    );
  }
}

class SubjectDiaryEntry {
  final String id;
  final String subjectKey;
  final DateTime date; // день записи (без времени)
  final String? text;  // заметка
  final List<SubjectDiaryFile> files; // файлы/фото
  SubjectDiaryEntry({
    required this.id,
    required this.subjectKey,
    required this.date,
    this.text,
    this.files = const [],
  });

  bool get hasText => (text ?? '').trim().isNotEmpty;
  bool get hasImages => files.any((f) => f.isImage);
  bool get hasDocs => files.any((f) => !f.isImage);
}

class SubjectDiaryFile {
  final String name;
  final int size;
  final String mime;
  final String url; // для моков: local://<id>
  const SubjectDiaryFile({
    required this.name,
    required this.size,
    required this.mime,
    required this.url,
  });

  bool get isImage => mime.startsWith('image/');
}

/// Публичная модель для внешних экранов
class SubjectDiaryPickedFile {
  final String name;
  final String mime;
  final Uint8List? bytes;
  const SubjectDiaryPickedFile({required this.name, required this.mime, this.bytes});
}

/// Внутренние модели выбора
class _PickedImage {
  final String name;
  final String mime;
  final Uint8List bytes;
  _PickedImage({required this.name, required this.mime, required this.bytes});
}

class _PickedFile {
  final String name;
  final String mime;
  final Uint8List? bytes; // может быть null, но для моков используем in-memory
  _PickedFile({required this.name, required this.mime, this.bytes});
}
