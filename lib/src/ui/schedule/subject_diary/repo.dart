part of subject_diary;

/// ===== РЕПОЗИТОРИЙ (мок)

abstract class SubjectDiaryRepository {
  Future<SubjectDiaryEntry> addText({
    required String subjectKey,
    required DateTime date,
    required String text,
    SubjectDiaryArgs? args,
  });

  Future<SubjectDiaryEntry> addConspect({
    required String subjectKey,
    required DateTime date,
    required List<_PickedImage> images,
    SubjectDiaryArgs? args,
  });

  Future<SubjectDiaryEntry> addFiles({
    required String subjectKey,
    required DateTime date,
    required List<_PickedFile> files,
    SubjectDiaryArgs? args,
  });

  // Публичная обертка для добавления файлов из других экранов
  Future<SubjectDiaryEntry> addFilesPublic({
    required String subjectKey,
    required DateTime date,
    required List<SubjectDiaryPickedFile> files,
    SubjectDiaryArgs? args,
  });

  Future<List<SubjectDiaryEntry>> listBySubject(String subjectKey);
  Future<List<SubjectDiaryEntry>> listByArgs(SubjectDiaryArgs args);
  Future<void> deleteEntry(String id);

  Uint8List? getLocalThumb(String url); // только для мок-превью локальных фото
  Uint8List? getFileBytes(String url);  // полные байты файла (для открытия)

  Future<SubjectDiaryEntry> updateTextEntry({required String id, required String newText});
  Future<SubjectDiaryEntry?> removeFileFromEntry({required String entryId, required String fileUrl});
  Future<void> removeAllFilesForEntry({required String entryId, required bool alsoDeleteEntryIfNoText});
  Future<void> deleteEntryCascade({required String entryId});
  Future<void> removeFilesForEntry({required String entryId, required bool images});

  static SubjectDiaryRepository instance = SubjectDiaryRepositorySupabase();
}

class SubjectDiaryRepositoryInMemory implements SubjectDiaryRepository {
  final _store = <String, List<SubjectDiaryEntry>>{}; // subjectKey -> entries (desc)
  final _thumbs = <String, Uint8List>{};              // url -> bytes (preview only)
  final _files  = <String, Uint8List>{};              // url -> full bytes
  int _seq = 0;

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Future<SubjectDiaryEntry> addText({
    required String subjectKey,
    required DateTime date,
    required String text,
    SubjectDiaryArgs? args,
  }) async {
    final e = SubjectDiaryEntry(
      id: (++_seq).toString(),
      subjectKey: subjectKey,
      date: DateTime(date.year, date.month, date.day),
      text: text.trim(),
    );
    _store.putIfAbsent(subjectKey, () => []).insert(0, e);
    return e;
  }

  @override
  Future<SubjectDiaryEntry> addConspect({
    required String subjectKey,
    required DateTime date,
    required List<_PickedImage> images,
    SubjectDiaryArgs? args,
  }) async {
    // найти запись с фото за этот день
    final existing = (await listBySubject(subjectKey))
        .where((e) => _sameDay(e.date, date) && e.hasImages)
        .toList();

    // закачать новые изображения
    final newFiles = <SubjectDiaryFile>[];
    final baseId = (++_seq).toString();
    for (var i = 0; i < images.length; i++) {
      final url = 'local://$baseId-img-$i';
      _thumbs[url] = images[i].bytes;
      _files[url]  = images[i].bytes;
      newFiles.add(SubjectDiaryFile(
        name: images[i].name,
        size: images[i].bytes.lengthInBytes,
        mime: images[i].mime,
        url: url,
      ));
    }

    if (existing.isNotEmpty) {
      // аппенд к первой найденной записи
      final list = _store[subjectKey]!;
      final idx = list.indexWhere((e) => e.id == existing.first.id);
      final old = list[idx];
      final merged = SubjectDiaryEntry(
        id: old.id,
        subjectKey: old.subjectKey,
        date: old.date,
        text: old.text,
        files: [...old.files, ...newFiles],
      );
      list[idx] = merged;
      return merged;
    } else {
      final e = SubjectDiaryEntry(
        id: baseId,
        subjectKey: subjectKey,
        date: DateTime(date.year, date.month, date.day),
        text: null,
        files: newFiles,
      );
      _store.putIfAbsent(subjectKey, () => []).insert(0, e);
      return e;
    }
  }

  @override
  Future<SubjectDiaryEntry> addFiles({
    required String subjectKey,
    required DateTime date,
    required List<_PickedFile> files,
    SubjectDiaryArgs? args,
  }) async {
    // найти запись с документами за этот день
    final existing = (await listBySubject(subjectKey))
        .where((e) => _sameDay(e.date, date) && e.hasDocs)
        .toList();

    // закачать файлы
    final newFiles = <SubjectDiaryFile>[];
    final baseId = (++_seq).toString();
    for (var i = 0; i < files.length; i++) {
      final url = 'local://$baseId-file-$i';
      if (files[i].bytes != null) {
        _files[url] = files[i].bytes!;
        if (files[i].mime.startsWith('image/')) {
          _thumbs[url] = files[i].bytes!;
        }
      }
      newFiles.add(SubjectDiaryFile(
        name: files[i].name,
        size: files[i].bytes?.lengthInBytes ?? 0,
        mime: files[i].mime,
        url: url,
      ));
    }

    if (existing.isNotEmpty) {
      final list = _store[subjectKey]!;
      final idx = list.indexWhere((e) => e.id == existing.first.id);
      final old = list[idx];
      final merged = SubjectDiaryEntry(
        id: old.id,
        subjectKey: old.subjectKey,
        date: old.date,
        text: old.text,
        files: [...old.files, ...newFiles],
      );
      list[idx] = merged;
      return merged;
    } else {
      final e = SubjectDiaryEntry(
        id: baseId,
        subjectKey: subjectKey,
        date: DateTime(date.year, date.month, date.day),
        text: null,
        files: newFiles,
      );
      _store.putIfAbsent(subjectKey, () => []).insert(0, e);
      return e;
    }
  }

  @override
  Future<SubjectDiaryEntry> addFilesPublic({
    required String subjectKey,
    required DateTime date,
    required List<SubjectDiaryPickedFile> files,
    SubjectDiaryArgs? args,
  }) async {
    final list = <SubjectDiaryFile>[];
    final baseId = (++_seq).toString();
    for (var i = 0; i < files.length; i++) {
      final url = 'local://$baseId-file-$i';
      if (files[i].bytes != null) {
        _files[url] = files[i].bytes!;
        if (files[i].mime.startsWith('image/')) {
          _thumbs[url] = files[i].bytes!;
        }
      }
      list.add(SubjectDiaryFile(
        name: files[i].name,
        size: files[i].bytes?.lengthInBytes ?? 0,
        mime: files[i].mime,
        url: url,
      ));
    }
    final e = SubjectDiaryEntry(
      id: baseId,
      subjectKey: subjectKey,
      date: DateTime(date.year, date.month, date.day),
      text: null,
      files: list,
    );
    _store.putIfAbsent(subjectKey, () => []).insert(0, e);
    return e;
  }

  @override
  Future<List<SubjectDiaryEntry>> listBySubject(String subjectKey) async {
    return List<SubjectDiaryEntry>.from(_store[subjectKey] ?? const []);
  }

  @override
  Future<List<SubjectDiaryEntry>> listByArgs(SubjectDiaryArgs args) {
    return listBySubject(args.fallbackSubjectKey);
  }

  @override
  Future<void> deleteEntry(String id) async {
    for (final key in _store.keys) {
      _store[key]!.removeWhere((e) => e.id == id);
    }
  }

  @override
  Uint8List? getLocalThumb(String url) => _thumbs[url];

  @override
  Uint8List? getFileBytes(String url) => _files[url];

  @override
  Future<SubjectDiaryEntry> updateTextEntry({required String id, required String newText}) async {
    for (final key in _store.keys) {
      final list = _store[key]!;
      final idx = list.indexWhere((e) => e.id == id);
      if (idx != -1) {
        final old = list[idx];
        final updated = SubjectDiaryEntry(
          id: old.id,
          subjectKey: old.subjectKey,
          date: old.date,
          text: newText.trim(),
          files: old.files,
        );
        list[idx] = updated;
        return updated;
      }
    }
    throw Exception('Entry not found');
  }

  @override
  Future<SubjectDiaryEntry?> removeFileFromEntry({required String entryId, required String fileUrl}) async {
    for (final key in _store.keys) {
      final list = _store[key]!;
      final idx = list.indexWhere((e) => e.id == entryId);
      if (idx != -1) {
        final old = list[idx];
        final nf = List<SubjectDiaryFile>.from(old.files)..removeWhere((f) => f.url == fileUrl);
        _thumbs.remove(fileUrl);
        _files.remove(fileUrl);
        final updated = SubjectDiaryEntry(
          id: old.id,
          subjectKey: old.subjectKey,
          date: old.date,
          text: old.text,
          files: nf,
        );
        list[idx] = updated;
        return updated;
      }
    }
    return null;
  }

  @override
  Future<void> removeAllFilesForEntry({required String entryId, required bool alsoDeleteEntryIfNoText}) async {
    for (final key in _store.keys) {
      final list = _store[key] ?? const <SubjectDiaryEntry>[];
      final idx = list.indexWhere((e) => e.id == entryId);
      if (idx != -1) {
        final old = list[idx];
        // очистим кеши
        for (final f in old.files) {
          _thumbs.remove(f.url);
          _files.remove(f.url);
        }
        if (alsoDeleteEntryIfNoText && (old.text ?? '').trim().isEmpty) {
          _store[key]!.removeAt(idx);
        } else {
          _store[key]![idx] = SubjectDiaryEntry(
            id: old.id,
            subjectKey: old.subjectKey,
            date: old.date,
            text: old.text,
            files: const [],
          );
        }
        return;
      }
    }
  }

  @override
  Future<void> deleteEntryCascade({required String entryId}) async {
    for (final key in _store.keys) {
      final list = _store[key] ?? const <SubjectDiaryEntry>[];
      final idx = list.indexWhere((e) => e.id == entryId);
      if (idx != -1) {
        for (final f in list[idx].files) { _thumbs.remove(f.url); _files.remove(f.url); }
        _store[key]!.removeAt(idx);
        return;
      }
    }
  }

  @override
  Future<void> removeFilesForEntry({required String entryId, required bool images}) async {
    for (final key in _store.keys) {
      final list = _store[key] ?? const <SubjectDiaryEntry>[];
      final idx = list.indexWhere((e) => e.id == entryId);
      if (idx != -1) {
        final old = list[idx];
        final filtered = old.files.where((f) => images ? !f.isImage : f.isImage).toList();
        _store[key]![idx] = SubjectDiaryEntry(
          id: old.id,
          subjectKey: old.subjectKey,
          date: old.date,
          text: old.text,
          files: filtered,
        );
        return;
      }
    }
  }
}
