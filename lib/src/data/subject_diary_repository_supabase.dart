part of subject_diary;

/// Реализация репозитория дневника через Supabase RPC + Yandex S3.
class SubjectDiaryRepositorySupabase implements SubjectDiaryRepository {
  final SupabaseClient _sb = Supabase.instance.client;

  // Кэши как в мок-репозитории: синхронные геттеры отдают уже загруженные байты
  final Map<String, Uint8List> _thumbs = <String, Uint8List>{}; // url -> bytes
  final Map<String, Uint8List> _files = <String, Uint8List>{}; // url -> bytes

  String? _cachedTeamId;
  final Map<String, String> _cachedTeamIdBySubject = <String, String>{};
  final Map<String, _DiaryOfferingContext> _cachedOfferingContext =
      <String, _DiaryOfferingContext>{};
  S3Client? _s3;

  SubjectDiaryRepositorySupabase() {
    if (YandexStorageConfig.isConfigured) {
      _s3 = S3Client(
        accessKey: YandexStorageConfig.accessKey,
        secretKey: YandexStorageConfig.secretKey,
        bucketName: YandexStorageConfig.bucketName,
        region: YandexStorageConfig.region,
        endpoint: YandexStorageConfig.endpoint,
      );
    }
  }

  S3Client? get _legacyS3Client {
    if (!YandexStorageConfig.isConfigured) return null;
    return _s3 ??= S3Client(
      accessKey: YandexStorageConfig.accessKey,
      secretKey: YandexStorageConfig.secretKey,
      bucketName: YandexStorageConfig.bucketName,
      region: YandexStorageConfig.region,
      endpoint: YandexStorageConfig.endpoint,
    );
  }

  // ===== SubjectDiaryRepository API =====

  @override
  Future<SubjectDiaryEntry> addText({
    required String subjectKey,
    required DateTime date,
    required String text,
    SubjectDiaryArgs? args,
  }) async {
    if (args?.hasSubjectOffering == true) {
      return _addTextForOffering(args: args!, date: date, text: text);
    }

    final String teamId = await _ensureTeamIdForSubject(subjectKey);
    if (teamId.isEmpty) {
      developer.log(
          'No teamId resolved for subject="$subjectKey"; using generic team for addText',
          name: 'DiaryRepo',
          level: 900);
      final fallbackId = await _ensureTeamId();
      if (fallbackId.isNotEmpty) {
        return await SubjectDiaryRepositorySupabase()
            .addText(subjectKey: subjectKey, date: date, text: text);
      }
    }
    final String? lessonId =
        await _findLessonIdFor(subjectKey: subjectKey, date: date);

    final String day = _yyyyMmDd(date);
    final params = <String, dynamic>{
      'p_team_id': teamId,
      'p_lesson_id': lessonId,
      'p_entry_date': day,
      'p_text': text,
    };

    String entryId = '';
    try {
      final res = await _sb.rpc('add_subject_diary_entry', params: params);
      entryId = (res ?? '').toString();
    } catch (e) {
      // silent; UI перезагрузит список
      rethrow;
    }

    return SubjectDiaryEntry(
      id: entryId.isEmpty ? _randomId() : entryId,
      subjectKey: subjectKey,
      date: DateTime(date.year, date.month, date.day),
      text: text.trim(),
      files: const [],
    );
  }

  @override
  Future<SubjectDiaryEntry> addConspect({
    required String subjectKey,
    required DateTime date,
    required List<_PickedImage> images,
    SubjectDiaryArgs? args,
  }) async {
    if (args?.hasSubjectOffering == true) {
      final context = await _resolveOfferingContext(args!);
      final String entryId =
          await _ensureEntryForArgs(args: args, date: date, context: context);
      await _uploadAndAttachFiles(
        entryId: entryId,
        date: date,
        teamId: context.teamId,
        files: images
            .map((e) =>
                (_UploadPayload(name: e.name, mime: e.mime, bytes: e.bytes)))
            .toList(),
      );
      return SubjectDiaryEntry(
        id: entryId,
        subjectKey: args.displayTitle,
        date: DateTime(date.year, date.month, date.day),
        text: null,
        files: const [],
      );
    }

    // Найдём/создадим запись за день для данного предмета, затем закачаем файлы
    final String entryId =
        await _ensureEntryFor(subjectKey: subjectKey, date: date);
    await _uploadAndAttachFiles(
      entryId: entryId,
      date: date,
      files: images
          .map((e) =>
              (_UploadPayload(name: e.name, mime: e.mime, bytes: e.bytes)))
          .toList(),
    );

    // Возвращаем заглушку; UI перезагрузит список
    return SubjectDiaryEntry(
      id: entryId,
      subjectKey: subjectKey,
      date: DateTime(date.year, date.month, date.day),
      text: null,
      files: const [],
    );
  }

  @override
  Future<SubjectDiaryEntry> addFiles({
    required String subjectKey,
    required DateTime date,
    required List<_PickedFile> files,
    SubjectDiaryArgs? args,
  }) async {
    if (args?.hasSubjectOffering == true) {
      final context = await _resolveOfferingContext(args!);
      final list = <_UploadPayload>[];
      for (final f in files) {
        if (f.bytes == null) continue;
        list.add(_UploadPayload(name: f.name, mime: f.mime, bytes: f.bytes!));
      }
      final String entryId =
          await _ensureEntryForArgs(args: args, date: date, context: context);
      await _uploadAndAttachFiles(
        entryId: entryId,
        date: date,
        teamId: context.teamId,
        files: list,
      );
      return SubjectDiaryEntry(
        id: entryId,
        subjectKey: args.displayTitle,
        date: DateTime(date.year, date.month, date.day),
        text: null,
        files: const [],
      );
    }

    final String entryId =
        await _ensureEntryFor(subjectKey: subjectKey, date: date);
    final list = <_UploadPayload>[];
    for (final f in files) {
      if (f.bytes == null) continue;
      list.add(_UploadPayload(name: f.name, mime: f.mime, bytes: f.bytes!));
    }
    await _uploadAndAttachFiles(entryId: entryId, date: date, files: list);

    return SubjectDiaryEntry(
      id: entryId,
      subjectKey: subjectKey,
      date: DateTime(date.year, date.month, date.day),
      text: null,
      files: const [],
    );
  }

  @override
  Future<SubjectDiaryEntry> addFilesPublic({
    required String subjectKey,
    required DateTime date,
    required List<SubjectDiaryPickedFile> files,
    SubjectDiaryArgs? args,
  }) async {
    if (args?.hasSubjectOffering == true) {
      final context = await _resolveOfferingContext(args!);
      final list = files
          .where((f) => f.bytes != null)
          .map((f) =>
              _UploadPayload(name: f.name, mime: f.mime, bytes: f.bytes!))
          .toList();
      final String entryId =
          await _ensureEntryForArgs(args: args, date: date, context: context);
      await _uploadAndAttachFiles(
        entryId: entryId,
        date: date,
        teamId: context.teamId,
        files: list,
      );
      return SubjectDiaryEntry(
        id: entryId,
        subjectKey: args.displayTitle,
        date: DateTime(date.year, date.month, date.day),
        text: null,
        files: const [],
      );
    }

    final String entryId =
        await _ensureEntryFor(subjectKey: subjectKey, date: date);
    final list = files
        .where((f) => f.bytes != null)
        .map((f) => _UploadPayload(name: f.name, mime: f.mime, bytes: f.bytes!))
        .toList();
    await _uploadAndAttachFiles(entryId: entryId, date: date, files: list);

    return SubjectDiaryEntry(
      id: entryId,
      subjectKey: subjectKey,
      date: DateTime(date.year, date.month, date.day),
      text: null,
      files: const [],
    );
  }

  @override
  Future<List<SubjectDiaryEntry>> listBySubject(String subjectKey) async {
    final String teamId = await _ensureTeamIdForSubject(subjectKey);
    final DateTime fromDate =
        DateTime.now().subtract(const Duration(days: 180));
    final params = <String, dynamic>{
      'p_team_id': teamId,
      'p_from': _yyyyMmDd(fromDate),
      'p_limit': 200,
    };

    try {
      final res = await _sb.rpc('get_my_subject_diary', params: params);
      final list = <SubjectDiaryEntry>[];
      if (res is List) {
        for (final it in res) {
          final m = Map<String, dynamic>.from(it as Map);
          final entry = _mapEntryRow(m);
          // файлы подгружаем отдельным RPC и префетчим байты (для синхронных превью)
          final files = await _listFiles(entry.id);
          final hasText = (entry.text ?? '').toString().trim().isNotEmpty;
          if (!hasText && files.isEmpty) {
            // Пропустим пустые записи
            continue;
          }
          final enriched = SubjectDiaryEntry(
            id: entry.id,
            subjectKey: entry.subjectKey,
            date: entry.date,
            text: entry.text,
            files: files,
          );
          list.add(enriched);
          // префетчим
          for (final f in files) {
            // изображения и файлы — оба, чтобы открыть по тапу без ожидания
            unawaited(_prefetchUrl(f.url, isImage: f.isImage));
          }
        }
      }
      // Сортировка по дате убыв.
      list.sort((a, b) => b.date.compareTo(a.date));
      return list;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<SubjectDiaryEntry>> listByArgs(SubjectDiaryArgs args) async {
    if (!args.hasSubjectOffering) {
      return listBySubject(args.fallbackSubjectKey);
    }

    final authorId = _sb.auth.currentUser?.id ?? '';
    final offeringId = args.subjectOfferingId!.trim();
    if (authorId.isEmpty || offeringId.isEmpty) return const [];

    try {
      final rows = await _sb
          .from('subject_diary_entries')
          .select(
            'id,team_id,author_id,lesson_id,entry_date,text,files_count,created_at,updated_at,subject_offering_id,subject_id,group_id,semester_number',
          )
          .eq('author_id', authorId)
          .eq('subject_offering_id', offeringId)
          .order('entry_date', ascending: false)
          .order('created_at', ascending: false)
          .limit(200);

      final list = <SubjectDiaryEntry>[];
      if (rows is List) {
        for (final it in rows) {
          final m = Map<String, dynamic>.from(it as Map);
          final entry = _mapEntryRow(m, fallbackSubjectKey: args.displayTitle);
          final files = await _listFiles(entry.id);
          if (!entry.hasText && files.isEmpty) continue;
          final enriched = SubjectDiaryEntry(
            id: entry.id,
            subjectKey: args.displayTitle,
            date: entry.date,
            text: entry.text,
            files: files,
          );
          list.add(enriched);
          for (final f in files) {
            unawaited(_prefetchUrl(f.url, isImage: f.isImage));
          }
        }
      }
      list.sort((a, b) => b.date.compareTo(a.date));
      return list;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> deleteEntry(String id) async {
    try {
      // Перед удалением записи удалим объекты в S3
      try {
        final files = await _sb
            .from('subject_diary_files')
            .select('yandex_key')
            .eq('entry_id', id);
        if (files is List && files.isNotEmpty) {
          final s3 = _legacyS3Client;
          for (final row in files) {
            final m = Map<String, dynamic>.from(row as Map);
            final key = (m['yandex_key'] ?? '').toString();
            if (s3 != null && key.isNotEmpty) {
              await s3.deleteObject(key: key);
            }
          }
        }
      } catch (_) {}

      await _sb.rpc('delete_subject_diary_entry', params: {'p_entry_id': id});
    } catch (_) {}
  }

  @override
  Uint8List? getLocalThumb(String url) => _thumbs[url];

  @override
  Uint8List? getFileBytes(String url) => _files[url];

  @override
  Future<SubjectDiaryEntry> updateTextEntry({
    required String id,
    required String newText,
  }) async {
    try {
      await _sb.rpc('update_subject_diary_text', params: {
        'p_entry_id': id,
        'p_text': newText,
      });
    } catch (_) {}
    // Возвращаем заглушку; UI всё равно перезагрузит список
    return SubjectDiaryEntry(
        id: id,
        subjectKey: '',
        date: DateTime.now(),
        text: newText,
        files: const []);
  }

  @override
  Future<SubjectDiaryEntry?> removeFileFromEntry({
    required String entryId,
    required String fileUrl,
  }) async {
    try {
      // 1) Получим файлы записи и найдём точный объект
      final files = await _listFiles(entryId);
      final file = files.firstWhere(
        (f) => f.url == fileUrl,
        orElse: () =>
            const SubjectDiaryFile(name: '', size: 0, mime: '', url: ''),
      );
      if (file.url.isEmpty) return null;

      // 2) Удалим файл в S3 (по yandex_key — нужно получить его через отдельный RPC)
      try {
        final meta = await _sb
            .from('subject_diary_files')
            .select('id,yandex_key')
            .eq('file_url', fileUrl)
            .limit(1);
        if (meta is List && meta.isNotEmpty) {
          final m = Map<String, dynamic>.from(meta.first as Map);
          final key = (m['yandex_key'] ?? '').toString();
          final s3 = _legacyS3Client;
          if (s3 != null && key.isNotEmpty) {
            await s3.deleteObject(key: key);
          }
        }
      } catch (_) {}

      // 3) Удалим запись файла через RPC (по id)
      try {
        final meta = await _sb
            .from('subject_diary_files')
            .select('id')
            .eq('file_url', fileUrl)
            .limit(1);
        if (meta is List && meta.isNotEmpty) {
          final m = Map<String, dynamic>.from(meta.first as Map);
          final fileId = (m['id'] ?? '').toString();
          if (fileId.isNotEmpty) {
            await _sb.rpc('remove_subject_diary_file',
                params: {'p_file_id': fileId});
          }
        }
      } catch (_) {}
    } catch (_) {}

    // Обновим локальные кэши (на всякий случай)
    _thumbs.remove(fileUrl);
    _files.remove(fileUrl);

    // Вернём актуальное состояние записи (текст + файлы), чтобы UI мог решить, удалять ли пустую запись
    try {
      final filesNow = await _listFiles(entryId);
      final row = await _sb
          .from('subject_diary_entries')
          .select('text, entry_date')
          .eq('id', entryId)
          .maybeSingle();
      String? text;
      DateTime date = DateTime.now();
      if (row != null) {
        final m = Map<String, dynamic>.from(row as Map);
        text = (m['text'] ?? '').toString();
        final s = (m['entry_date'] ?? '').toString();
        if (s.isNotEmpty) {
          try {
            date = DateTime.parse(s.length > 10 ? s : '${s}T00:00:00');
          } catch (_) {}
        }
      }
      return SubjectDiaryEntry(
        id: entryId,
        subjectKey: '',
        date: DateTime(date.year, date.month, date.day),
        text: (text ?? '').trim().isEmpty ? null : text,
        files: filesNow,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> removeAllFilesForEntry(
      {required String entryId, required bool alsoDeleteEntryIfNoText}) async {
    try {
      final files = await _sb
          .from('subject_diary_files')
          .select('id,yandex_key')
          .eq('entry_id', entryId);
      final s3 = _legacyS3Client;
      if (files is List) {
        for (final row in files) {
          final m = Map<String, dynamic>.from(row as Map);
          final fid = (m['id'] ?? '').toString();
          final key = (m['yandex_key'] ?? '').toString();
          if (s3 != null && key.isNotEmpty) {
            await s3.deleteObject(key: key);
          }
          if (fid.isNotEmpty) {
            await _sb
                .rpc('remove_subject_diary_file', params: {'p_file_id': fid});
          }
        }
      }
      if (alsoDeleteEntryIfNoText) {
        final row = await _sb
            .from('subject_diary_entries')
            .select('text')
            .eq('id', entryId)
            .maybeSingle();
        if (row != null) {
          final m = Map<String, dynamic>.from(row as Map);
          final text = (m['text'] ?? '').toString();
          if (text.trim().isEmpty) {
            await _sb.rpc('delete_subject_diary_entry',
                params: {'p_entry_id': entryId});
          }
        }
      }
    } catch (_) {}
  }

  @override
  Future<void> deleteEntryCascade({required String entryId}) async {
    try {
      final files = await _sb
          .from('subject_diary_files')
          .select('id,yandex_key')
          .eq('entry_id', entryId);
      final s3 = _legacyS3Client;
      if (files is List) {
        for (final row in files) {
          final m = Map<String, dynamic>.from(row as Map);
          final key = (m['yandex_key'] ?? '').toString();
          if (s3 != null && key.isNotEmpty) {
            await s3.deleteObject(key: key);
          }
        }
      }
      await _sb
          .rpc('delete_subject_diary_entry', params: {'p_entry_id': entryId});
    } catch (_) {}
  }

  @override
  Future<void> removeFilesForEntry(
      {required String entryId, required bool images}) async {
    try {
      // Выберем файлы этой записи и отфильтруем по mime (image/* или !image/*)
      final rows = await _sb
          .from('subject_diary_files')
          .select('id,yandex_key,mime')
          .eq('entry_id', entryId);
      if (rows is! List) return;
      final s3 = _legacyS3Client;
      for (final row in rows) {
        final m = Map<String, dynamic>.from(row as Map);
        final mime = (m['mime'] ?? '').toString();
        final isImg = mime.startsWith('image/');
        if (isImg != images) continue; // оставим «чужие» типы
        final key = (m['yandex_key'] ?? '').toString();
        final fid = (m['id'] ?? '').toString();
        if (s3 != null && key.isNotEmpty) {
          await s3.deleteObject(key: key);
        }
        if (fid.isNotEmpty) {
          await _sb
              .rpc('remove_subject_diary_file', params: {'p_file_id': fid});
        }
      }
    } catch (_) {}
  }

  // ===== Helpers =====

  SubjectDiaryEntry _mapEntryRow(
    Map<String, dynamic> m, {
    String? fallbackSubjectKey,
  }) {
    DateTime parseDate(dynamic v) {
      final s = (m['entry_date'] ?? m['date'] ?? '').toString();
      if (s.isEmpty) return DateTime.now();
      try {
        // Может прийти без времени
        return DateTime.parse(s.length > 10 ? s : '${s}T00:00:00Z');
      } catch (_) {
        return DateTime.now();
      }
    }

    return SubjectDiaryEntry(
      id: (m['id'] ?? '').toString(),
      subjectKey: (m['subject'] ??
              m['subject_key'] ??
              fallbackSubjectKey ??
              '')
          .toString(),
      date: parseDate(m['entry_date']),
      text: (m['text'] ?? m['note'] ?? '').toString().trim().isEmpty
          ? null
          : (m['text'] ?? m['note']).toString(),
      files: const [],
    );
  }

  Future<List<SubjectDiaryFile>> _listFiles(String entryId) async {
    try {
      final res = await _sb
          .rpc('get_subject_diary_files', params: {'p_entry_id': entryId});
      if (res is List) {
        final list =
            res.map((e) => Map<String, dynamic>.from(e as Map)).map((m) {
          final mime =
              (m['mime'] ?? m['file_mime'] ?? 'application/octet-stream')
                  .toString();
          final size = (m['size'] ?? m['size_bytes'] ?? 0) as int? ??
              int.tryParse((m['size'] ?? m['size_bytes'] ?? '0').toString()) ??
              0;
          final url = (m['url'] ?? m['file_url'] ?? '').toString();
          String name = (m['name'] ?? m['file_name'] ?? '').toString().trim();
          if (name.isEmpty) {
            // fallback из URL
            try {
              final seg = Uri.parse(url).pathSegments.isNotEmpty
                  ? Uri.parse(url).pathSegments.last
                  : '';
              if (seg.contains('_')) {
                name = seg.substring(seg.indexOf('_') + 1);
              } else {
                name = seg;
              }
            } catch (_) {
              final seg = url.split('/').isNotEmpty ? url.split('/').last : '';
              name =
                  seg.contains('_') ? seg.substring(seg.indexOf('_') + 1) : seg;
            }
          }
          if (name.isEmpty) {
            // окончательный фолбэк по MIME
            final ext = _extensionFromMimeOrName(mime: mime, name: '');
            final ts = DateTime.now().millisecondsSinceEpoch;
            name = 'file_$ts${ext}';
          }
          return SubjectDiaryFile(name: name, size: size, mime: mime, url: url);
        }).toList();
        return list;
      }
    } catch (_) {}
    return const [];
  }

  Future<void> _prefetchUrl(String url, {required bool isImage}) async {
    if (url.isEmpty) return;
    if (_files.containsKey(url) || _thumbs.containsKey(url)) return;
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final bytes = resp.bodyBytes;
        _files[url] = bytes;
        if (isImage) {
          _thumbs[url] = bytes; // без отдельного превью используем сам файл
        }
      }
    } catch (_) {}
  }

  Future<String> _ensureEntryFor(
      {required String subjectKey, required DateTime date}) async {
    // Пытаемся найти существующую запись по subject/date
    final list = await listBySubject(subjectKey);
    for (final e in list) {
      if (_sameDay(e.date, date)) return e.id;
    }
    // Нет — создаём пустую (или с текстом "")
    final created = await addText(subjectKey: subjectKey, date: date, text: '');
    return created.id;
  }

  Future<SubjectDiaryEntry> _addTextForOffering({
    required SubjectDiaryArgs args,
    required DateTime date,
    required String text,
  }) async {
    final context = await _resolveOfferingContext(args);
    final entryId = await _createOrUpdateOfferingEntry(
      args: args,
      date: date,
      text: text,
      context: context,
    );
    return SubjectDiaryEntry(
      id: entryId,
      subjectKey: args.displayTitle,
      date: DateTime(date.year, date.month, date.day),
      text: text.trim(),
      files: const [],
    );
  }

  Future<String> _ensureEntryForArgs({
    required SubjectDiaryArgs args,
    required DateTime date,
    required _DiaryOfferingContext context,
  }) async {
    final existing = await _findOfferingEntryId(
      args: args,
      date: date,
      context: context,
    );
    if (existing.isNotEmpty) return existing;
    return _createOrUpdateOfferingEntry(
      args: args,
      date: date,
      text: '',
      context: context,
    );
  }

  Future<String> _findOfferingEntryId({
    required SubjectDiaryArgs args,
    required DateTime date,
    required _DiaryOfferingContext context,
  }) async {
    final authorId = _sb.auth.currentUser?.id ?? '';
    if (authorId.isEmpty) return '';
    final lessonId = (args.lessonId ?? '').trim();
    try {
      dynamic query = _sb
          .from('subject_diary_entries')
          .select('id')
          .eq('author_id', authorId);
      if (lessonId.isNotEmpty) {
        query = query.eq('lesson_id', lessonId);
      } else {
        query = query
            .eq('subject_offering_id', context.subjectOfferingId)
            .eq('entry_date', _yyyyMmDd(date));
      }
      final row = await query.limit(1).maybeSingle();
      return (row?['id'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  Future<String> _createOrUpdateOfferingEntry({
    required SubjectDiaryArgs args,
    required DateTime date,
    required String text,
    required _DiaryOfferingContext context,
  }) async {
    final authorId = _sb.auth.currentUser?.id ?? '';
    if (authorId.isEmpty) {
      throw Exception('auth required');
    }
    if (context.teamId.isEmpty) {
      throw Exception('Команда предмета не найдена');
    }

    final entryDate = DateTime(date.year, date.month, date.day);
    final existingId = await _findOfferingEntryId(
      args: args,
      date: entryDate,
      context: context,
    );
    final cleanText = text.trim();
    final payload = <String, dynamic>{
      'team_id': context.teamId,
      'author_id': authorId,
      'lesson_id': _nullIfEmpty(args.lessonId),
      'entry_date': _yyyyMmDd(entryDate),
      'text': cleanText.isEmpty ? null : cleanText,
      'subject_offering_id': context.subjectOfferingId,
      'subject_id': _nullIfEmpty(context.subjectId),
      'group_id': _nullIfEmpty(context.groupId),
      'academic_year_id': _nullIfEmpty(context.academicYearId),
      'academic_term_id': _nullIfEmpty(context.academicTermId),
      'semester_number': context.semesterNumber,
    };

    if (existingId.isNotEmpty) {
      await _sb
          .from('subject_diary_entries')
          .update(payload)
          .eq('id', existingId);
      return existingId;
    }

    final row = await _sb
        .from('subject_diary_entries')
        .insert(payload)
        .select('id')
        .single();
    return (row['id'] ?? '').toString();
  }

  Future<_DiaryOfferingContext> _resolveOfferingContext(
      SubjectDiaryArgs args) async {
    final offeringId = args.subjectOfferingId?.trim() ?? '';
    if (offeringId.isEmpty) {
      return _DiaryOfferingContext(
        subjectOfferingId: '',
        subjectTitle: args.displayTitle,
        teamId: '',
      );
    }

    final cached = _cachedOfferingContext[offeringId];
    if (cached != null && cached.teamId.isNotEmpty) return cached;

    final offering = await _sb
        .from('subject_offerings')
        .select(
          'id,display_name,subject_id,group_id,academic_year_id,academic_term_id,semester_number',
        )
        .eq('id', offeringId)
        .maybeSingle();
    final offeringMap =
        offering == null ? <String, dynamic>{} : Map<String, dynamic>.from(offering);

    final team = await _sb
        .from('teams')
        .select('id,name')
        .eq('subject_offering_id', offeringId)
        .limit(1)
        .maybeSingle();
    var teamId = (team?['id'] ?? '').toString();
    if (teamId.isEmpty) {
      teamId = await _ensureTeamIdForSubject(args.fallbackSubjectKey);
    }

    final context = _DiaryOfferingContext(
      subjectOfferingId: offeringId,
      subjectTitle: (offeringMap['display_name'] ?? args.displayTitle).toString(),
      subjectId: _firstNonEmpty([
        offeringMap['subject_id'],
        args.subjectId,
      ]),
      groupId: _firstNonEmpty([
        offeringMap['group_id'],
        args.groupId,
      ]),
      academicYearId: (offeringMap['academic_year_id'] ?? '').toString(),
      academicTermId: (offeringMap['academic_term_id'] ?? '').toString(),
      semesterNumber:
          _asInt(offeringMap['semester_number']) ?? args.semesterNumber,
      teamId: teamId,
    );
    _cachedOfferingContext[offeringId] = context;
    return context;
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<String> _ensureTeamId() async {
    if ((_cachedTeamId ?? '').isNotEmpty) return _cachedTeamId!;
    try {
      // Используем тот же RPC, что и в разделе «Команды»
      final res = await _sb.rpc('get_my_teams');
      if (res is List && res.isNotEmpty) {
        final first = Map<String, dynamic>.from(res.first as Map);
        final id = (first['id'] ?? first['team_id'] ?? '').toString();
        if (id.isNotEmpty) {
          _cachedTeamId = id;
          return id;
        }
      }
    } catch (_) {}
    // Фолбэк: берём последнюю команду из team_members
    try {
      final data = await _sb.from('team_members').select('team_id').limit(1);
      if (data is List && data.isNotEmpty) {
        final id = (data.first['team_id'] ?? '').toString();
        if (id.isNotEmpty) {
          _cachedTeamId = id;
          return id;
        }
      }
    } catch (_) {}
    return '';
  }

  Future<String> _ensureTeamIdForSubject(String subjectKey) async {
    // Кэш по предмету
    final cached = _cachedTeamIdBySubject[subjectKey.trim()];
    if ((cached ?? '').isNotEmpty) return cached!;

    final want = _normalizeSubject(subjectKey);

    // 1) Пробуем найти среди моих команд (самый надёжный источник)
    try {
      final teams = await _sb.rpc('get_my_teams');
      if (teams is List) {
        for (final it in teams) {
          final m = Map<String, dynamic>.from(it as Map);
          final tName = (m['name'] ?? m['team_name'] ?? '').toString();
          final norm = _normalizeSubject(tName);
          if (norm == want) {
            final id = (m['id'] ?? m['team_id'] ?? '').toString();
            if (id.isNotEmpty) {
              _cachedTeamIdBySubject[subjectKey.trim()] = id;
              return id;
            }
          }
        }
      }
    } catch (_) {}

    // 2) Фолбэк: поиск через уроки и teams по group_name
    try {
      final today = DateTime.now();
      final resp = await _sb.rpc('get_my_lessons', params: {
        'p_from': _yyyyMmDd(DateTime(today.year, today.month, today.day - 14)),
        'p_days': 60,
      });
      if (resp is List) {
        for (final it in resp) {
          final m = Map<String, dynamic>.from(it as Map);
          final raw = (m['subject'] ?? '').toString();
          final cleaned = _normalizeSubject(raw);
          if (cleaned != want) continue;

          final groupName = (m['group_name'] ?? m['group'] ?? '').toString();
          if (groupName.isNotEmpty) {
            final q = await _sb
                .from('teams')
                .select('id,name,group_name')
                .eq('group_name', groupName)
                .limit(50);
            if (q is List) {
              for (final row in q) {
                final rm = Map<String, dynamic>.from(row as Map);
                final tName = (rm['name'] ?? '').toString();
                if (_normalizeSubject(tName) == want) {
                  final id = (rm['id'] ?? '').toString();
                  if (id.isNotEmpty) {
                    _cachedTeamIdBySubject[subjectKey.trim()] = id;
                    return id;
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    // 3) Никаких совпадений — лучше вернуть пусто, чем неправильную команду
    return '';
  }

  Future<String?> _findLessonIdFor(
      {required String subjectKey, required DateTime date}) async {
    try {
      final first = DateTime(date.year, date.month, date.day);
      final last = DateTime(date.year, date.month, date.day);
      final days = last.difference(first).inDays + 1; // 1 день
      final resp = await _sb.rpc('get_my_lessons', params: {
        'p_from': _yyyyMmDd(first),
        'p_days': days,
      });
      if (resp is List) {
        final norm = _normalizeSubject(subjectKey);
        for (final it in resp) {
          final m = Map<String, dynamic>.from(it as Map);
          final raw = (m['subject'] ?? '').toString();
          final cleaned = _normalizeSubject(raw);
          if (cleaned == norm) {
            return (m['id'] ?? '').toString();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String _normalizeSubject(String s) {
    // Удаляем суффиксы вида (л.)/(пр.)/(лаб.) в конце строки
    final cleaned =
        s.replaceAll(RegExp(r"\((л|пр|лаб)\.\)\s*$"), '').trim().toLowerCase();
    return cleaned;
  }

  String _yyyyMmDd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _randomId() =>
      'tmp-${DateTime.now().microsecondsSinceEpoch}-${io.Platform.numberOfProcessors}';

  String? _nullIfEmpty(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }

  String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }

  Future<void> _uploadAndAttachFiles({
    required String entryId,
    required DateTime date,
    String? teamId,
    required List<_UploadPayload> files,
  }) async {
    if (_s3 == null) {
      throw Exception('Yandex Storage не настроен');
    }
    final String resolvedTeamId = (teamId ?? '').isNotEmpty
        ? teamId!
        : await _ensureTeamId();
    final String userId = _sb.auth.currentUser?.id ?? 'anon';
    final String day =
        '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';

    for (final f in files) {
      final ext = _extensionFromMimeOrName(mime: f.mime, name: f.name);
      final safeName = _safeFileName(f.name, fallbackExt: ext);
      // Сохраняем оригинальное имя в конце ключа (для отображения по URL)
      final key =
          'diaries/$resolvedTeamId/$userId/$day/${_randomId()}_${safeName}';
      final upload = await _s3!.putObject(
        key: key,
        body: f.bytes,
        contentType: f.mime,
      );
      if (!(upload.success)) {
        // пропускаем неуспешные
        continue;
      }
      final fileUrl = upload.fileUrl ?? '';
      try {
        await _sb.rpc('add_subject_diary_file', params: {
          'p_entry_id': entryId,
          'p_yandex_key': key,
          'p_file_url': fileUrl,
          'p_mime': f.mime,
          'p_size': f.bytes.length,
          'p_thumb_url': null,
        });
      } catch (_) {}

      // Положим в кэш, чтобы UI сразу показал
      _files[fileUrl] = f.bytes;
      if (f.mime.startsWith('image/')) {
        _thumbs[fileUrl] = f.bytes;
      }
    }
  }

  String _extensionFromMimeOrName(
      {required String mime, required String name}) {
    String? fromMime() {
      switch (mime) {
        case 'image/png':
          return '.png';
        case 'image/jpeg':
          return '.jpg';
        case 'image/gif':
          return '.gif';
        case 'image/webp':
          return '.webp';
        case 'application/pdf':
          return '.pdf';
        case 'application/msword':
          return '.doc';
        case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
          return '.docx';
        case 'application/vnd.ms-excel':
          return '.xls';
        case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
          return '.xlsx';
        case 'application/vnd.ms-powerpoint':
          return '.ppt';
        case 'application/vnd.openxmlformats-officedocument.presentationml.presentation':
          return '.pptx';
        case 'text/plain':
          return '.txt';
        case 'text/csv':
          return '.csv';
        case 'application/zip':
          return '.zip';
        default:
          return null;
      }
    }

    return fromMime() ?? (name.contains('.') ? '.${name.split('.').last}' : '');
  }

  String _safeFileName(String rawName, {required String fallbackExt}) {
    String base = rawName.trim();
    if (base.isEmpty) base = 'file$fallbackExt';
    // Уберём каталоги
    if (base.contains('/')) base = base.split('/').last;
    if (base.contains('\\')) base = base.split('\\').last;
    // Если нет расширения — добавим
    if (!base.contains('.')) base = '$base$fallbackExt';
    // Санитайз
    base = base.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), '_');
    if (base.length > 80) {
      final ext = '.${base.split('.').last}';
      final stem = base.substring(0, 80 - ext.length);
      base = '$stem$ext';
    }
    return base;
  }
}

class _UploadPayload {
  final String name;
  final String mime;
  final Uint8List bytes;
  _UploadPayload({required this.name, required this.mime, required this.bytes});
}

class _DiaryOfferingContext {
  final String subjectOfferingId;
  final String subjectTitle;
  final String? subjectId;
  final String? groupId;
  final String? academicYearId;
  final String? academicTermId;
  final int? semesterNumber;
  final String teamId;

  const _DiaryOfferingContext({
    required this.subjectOfferingId,
    required this.subjectTitle,
    required this.teamId,
    this.subjectId,
    this.groupId,
    this.academicYearId,
    this.academicTermId,
    this.semesterNumber,
  });
}
