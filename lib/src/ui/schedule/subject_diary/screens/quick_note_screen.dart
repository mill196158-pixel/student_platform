part of subject_diary;

/// ===== ЭКРАН ДНЯ ПРЕДМЕТА

class SubjectQuickNoteScreen extends StatefulWidget {
  final String subjectKey;
  final SubjectDiaryArgs? args;
  final DateTime date;

  SubjectQuickNoteScreen({
    super.key,
    String? subjectKey,
    this.args,
    required this.date,
  }) : subjectKey =
            subjectKey ?? args?.subjectTitle ?? args?.legacySubjectKey ?? 'Предмет';

  @override
  State<SubjectQuickNoteScreen> createState() => _SubjectQuickNoteScreenState();
}

class _SubjectQuickNoteScreenState extends State<SubjectQuickNoteScreen> {
  final _repo = SubjectDiaryRepository.instance;

  late final SubjectDiaryArgs _args =
      widget.args ?? SubjectDiaryArgs.legacy(widget.subjectKey);
  late final String _subjectKey = _args.displayTitle;
  late DateTime _day;
  bool _loading = true;
  List<SubjectDiaryEntry> _dayEntries = [];
  bool _isEditMode = false;
  // Пер-блоковый режим редактирования для фото-наборов
  final Set<String> _editingEntries = <String>{};
  // debounce + optimistic deletion (minimal impl for current usage)
  final Set<String> _pendingDeletedUrls = <String>{};
  Timer? _reloadDebounce;
  bool _suppressRealtime = false;

  void _scheduleReload([Duration delay = const Duration(milliseconds: 400)]) {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(delay, () async {
      if (!mounted) return;
      await _loadDay();
    });
  }

  void _toggleEdit(String entryId) {
    setState(() {
      if (_editingEntries.contains(entryId)) {
        _editingEntries.remove(entryId);
      } else {
        _editingEntries.add(entryId);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final base = widget.date;
    _day = DateTime(base.year, base.month, base.day);
    _loadDay();
    diaryRealtimeSuspended.value = true; // отписать родителя на время работы экрана дня
    _subscribeDiaryRealtime(anchor: _day);
  }

  Future<void> _loadDay() async {
    setState(() => _loading = true);
    final all = await _repo.listByArgs(_args);
    _dayEntries = all.where((e) =>
        e.date.year == _day.year && e.date.month == _day.month && e.date.day == _day.day).toList();
    setState(() => _loading = false);
  }

  // realtime
  RealtimeChannel? _diaryEntriesCh;
  RealtimeChannel? _diaryFilesCh;

  void _subscribeDiaryRealtime({required DateTime anchor}) {
    final client = Supabase.instance.client;
    _diaryEntriesCh = client
        .channel('public:subject_diary_entries')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'subject_diary_entries',
          callback: (_) => _reloadDiary(anchor: anchor),
        )
        .subscribe();

    _diaryFilesCh = client
        .channel('public:subject_diary_files')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'subject_diary_files',
          callback: (_) => _reloadDiary(anchor: anchor),
        )
        .subscribe();
  }

  Future<void> _reloadDiary({required DateTime anchor}) async {
    await _loadDay();
  }

  @override
  void dispose() {
    final client = Supabase.instance.client;
    if (_diaryEntriesCh != null) client.removeChannel(_diaryEntriesCh!);
    if (_diaryFilesCh != null) client.removeChannel(_diaryFilesCh!);
    diaryRealtimeSuspended.value = false; // вернуть родителю realtime
    super.dispose();
  }

  String get _dateStr =>
      '${_day.day.toString().padLeft(2, '0')}.${_day.month.toString().padLeft(2, '0')}.${_day.year}';

  Future<bool> _confirm(BuildContext context, String message) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Подтверждение', style: TextStyle(color: Colors.black)),
        content: Text(message, style: const TextStyle(color: Colors.black)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    return res ?? false;
  }

  // ==== ACTION SHEET (из троеточия) ====
  Future<void> _openActionsSheet() async {
    await showModalBottomSheet(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: _AddBranchPanel(
              tinted: true,
              onNewText: _dayEntries.any((e) => e.hasText)
                  ? () async {}
                  : () {
                      Navigator.pop(ctx);
                      _openNewNoteSheet();
                    },
              disableNewText: _dayEntries.any((e) => e.hasText),
              onPickGallery: () async {
                Navigator.pop(ctx);
                final ok = await _openPhotoConspect();
                if (ok && mounted) _loadDay();
              },
              onPickCamera: () async {
                Navigator.pop(ctx);
                final ok = await _openPhotoConspect(); // камера внутри экрана
                if (ok && mounted) _loadDay();
              },
              onAddFiles: () async {
                Navigator.pop(ctx);
                await _pickFilesAndSave();
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalPhotos = _dayEntries.fold<int>(0, (s, e) => s + e.files.where((f) => f.isImage).length);
    final notesCount = _dayEntries.where((e) => e.hasText).length;

    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 128,
            child: _ModelHeader(
              title: widget.subjectKey,
              subtitle: _dateStr, // оставить только дату
              subtitle2: null, // убрать счётчики чтобы не вылезал текст
              trailing: IconButton(
                tooltip: 'Добавить',
                icon: const Icon(Icons.more_horiz),
                onPressed: _openActionsSheet,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadDay,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 60),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_dayEntries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 36),
                      child: _CatEmptyState(),
                    )
                  else
                    ..._buildDayContent(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDayContent(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final repo = _repo;

    final noteEntries  = _dayEntries.where((e) => e.hasText).toList();
    final photoEntries = _dayEntries.where((e) => e.hasImages).toList();
    final fileEntries  = _dayEntries.where((e) => e.hasDocs).toList();

    final blocks = <Widget>[];

    // Фото-конспекты
    if (photoEntries.isNotEmpty) {
      blocks.add(const _SectionTitle('Конспекты (фото)'));
      blocks.add(const SizedBox(height: 8));

      for (final e in photoEntries) {
        final imgs = e.files.where((f) => f.isImage).toList();
        final isEdit = _editingEntries.contains(e.id);
        if (imgs.isEmpty) continue;
        blocks.add(Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDeco(ctx),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PhotosGrid(
                images: imgs
                    .where((f) => repo.getFileBytes(f.url) != null || repo.getLocalThumb(f.url) != null)
                    .map((f) => _PickedImage(
                          name: f.name,
                          mime: f.mime,
                          bytes: repo.getFileBytes(f.url) ?? repo.getLocalThumb(f.url)!,
                        ))
                    .toList(),
                onRemove: (i) => _removeSingleImage(entryId: e.id, fileUrl: imgs[i].url),
                onOpen: (i) => _openImageViewer(ctx, imgs, i),
                editMode: isEdit,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SmallActionButton(
                      icon: isEdit ? Icons.check_rounded : Icons.edit_rounded,
                      label: isEdit ? 'Готово' : 'Изменить',
                      onTap: () => _toggleEdit(e.id),
                    ),
                    const SizedBox(width: 8),
                    _SmallActionButton(
                      icon: Icons.delete_outline_rounded,
                      label: 'Удалить',
                      kind: _ActionKind.danger,
                      onTap: () async {
                        final ok = await _confirm(ctx, 'Удалить этот набор фото?');
                        if (!ok) return;
                        await _repo.removeFilesForEntry(entryId: e.id, images: true);
                        await _loadDay();
                        if (mounted) setState(() => _editingEntries.remove(e.id));
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Набор фото удалён')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ));
        blocks.add(const SizedBox(height: 10));
      }
    }

    // Заметки
    if (noteEntries.isNotEmpty) {
      blocks.add(const _SectionTitle('Заметки'));
      blocks.add(const SizedBox(height: 8));
      for (final e in noteEntries) {
        blocks.add(Container(
          padding: const EdgeInsets.all(14),
          decoration: _cardDeco(ctx),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.text!.trim(),
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      fontSize: 16,
                      color: Colors.black,
                      height: 1.25,
                    ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: _InlineActions(
                  onEdit: () => _openEditNoteSheet(entry: e),
                  onDelete: () async {
                    final ok = await _confirm(ctx, 'Удалить эту заметку?');
                    if (!ok) return;
                    // Сначала очищаем текст
                    await _repo.updateTextEntry(id: e.id, newText: '');
                    await _loadDay();
                    // Если запись осталась пустой (без файлов и без текста) — удаляем
                    final still = _dayEntries.where((x) => x.id == e.id).toList();
                    if (still.isNotEmpty) {
                      final it = still.first;
                      final empty = !(it.hasText) && !(it.hasImages) && !(it.hasDocs);
                      if (empty) {
                        await _repo.deleteEntry(it.id);
                        await _loadDay();
                      }
                    }
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Заметка удалена')));
                    }
                  },
                ),
              ),
            ],
          ),
        ));
        blocks.add(const SizedBox(height: 10));
      }
    }

    // Файлы
    if (fileEntries.isNotEmpty) {
      blocks.add(const _SectionTitle('Файлы'));
      blocks.add(const SizedBox(height: 8));
      for (final e in fileEntries) {
        final files = e.files.where((f) => !f.isImage).toList();
        if (files.isEmpty) continue;
        blocks.add(Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDeco(ctx),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...files.map((f) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _FileRow(
                      name: f.name,
                      size: f.size,
                      mime: f.mime,
                      onDownload: () async => _openFile(ctx, f),
                      onDelete: () => _removeSingleFile(entryId: e.id, fileUrl: f.url),
                    ),
                  )),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final ok = await _confirm(ctx, 'Удалить этот набор файлов?');
                    if (!ok) return;
                    await _repo.removeFilesForEntry(entryId: e.id, images: false);
                    await _loadDay();
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Набор файлов удалён')));
                    }
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Удалить набор'),
                ),
              ),
            ],
          ),
        ));
        blocks.add(const SizedBox(height: 10));
      }
    }

    return blocks;
  }

  // --- actions ---

  void _openNewNoteSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _NewNoteSheet(
        subjectKey: _subjectKey,
        args: _args.copyWith(date: _day),
        date: _day,
        onSaved: () async {
          Navigator.pop(ctx);
          await _loadDay();
        },
      ),
    );
  }

  void _openEditNoteSheet({required SubjectDiaryEntry entry}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _EditNoteSheet(
        entryId: entry.id,
        initialText: entry.text ?? '',
        onSaved: () async {
          Navigator.pop(ctx);
          await _loadDay();
        },
      ),
    );
  }

  Future<bool> _openPhotoConspect() async {
    final saved = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SubjectPhotoConspectScreen(
          subjectKey: _subjectKey,
          args: _args.copyWith(date: _day),
          date: _day,
        ),
      ),
    );
    if (saved == true) await _loadDay();
    if (mounted) setState(() => _editingEntries.clear());
    return saved == true;
  }

  Future<void> _pickFilesAndSave() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (result == null || result.files.isEmpty) return;

    final files = <_PickedFile>[];
    for (final f in result.files) {
      final bytes = f.bytes;
      final name  = f.name;
      String mime  = _detectMime(name);
      if (mime.startsWith('image/')) {
        mime = 'application/octet-stream';
      }
      files.add(_PickedFile(name: name, mime: mime, bytes: bytes));
    }

    await SubjectDiaryRepository.instance.addFiles(
      subjectKey: _subjectKey,
      args: _args.copyWith(date: _day),
      date: _day,
      files: files,
    );
    if (mounted) {
      await _loadDay();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Файлы добавлены')));
    }
  }

  Future<void> _openFile(BuildContext ctx, SubjectDiaryFile f) async {
    final bytes = _repo.getFileBytes(f.url);
    if (bytes == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Файл недоступен')));
      return;
    }
    try {
      final dir  = await getTemporaryDirectory();
      final path = '${dir.path}/${f.name}';
      final file = io.File(path);
      await file.writeAsBytes(bytes, flush: true);
      await OpenFilex.open(path);
    } catch (e) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Не удалось открыть: $e')));
    }
  }

  Future<void> _openImageViewer(BuildContext ctx, List<SubjectDiaryFile> imgs, int start) async {
    final controller = PageController(initialPage: start);
    int cur = start;

    await showDialog(
      context: ctx,
      barrierColor: Colors.black.withOpacity(.95),
      builder: (_) => StatefulBuilder(
        builder: (dCtx, setS) {
          return GestureDetector(
            onVerticalDragEnd: (_) => Navigator.pop(dCtx),
            child: Stack(
              children: [
                PageView.builder(
                  controller: controller,
                  itemCount: imgs.length,
                  onPageChanged: (i) => setS(() => cur = i),
                  itemBuilder: (c, i) {
                    final b = _repo.getFileBytes(imgs[i].url) ?? _repo.getLocalThumb(imgs[i].url);
                    return Center(
                      child: InteractiveViewer(
                        child: b != null ? Image.memory(b, fit: BoxFit.contain) : const SizedBox(),
                      ),
                    );
                  },
                ),

                // Мягкий градиент под верхней панелью
                Positioned(
                  left: 0, right: 0, top: 0,
                  child: IgnorePointer(
                    ignoring: true,
                    child: Container(
                      height: 96,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                          colors: [Color(0xAA000000), Color(0x33000000), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                ),

                // Верхняя панель: закрыть • имя файла • скачать
                Positioned(
                  top: 8, left: 8, right: 8,
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        _viewerIconButton(icon: Icons.close, onTap: () => Navigator.pop(dCtx)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(.35),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              imgs[cur].name,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _viewerIconButton(
                          icon: Icons.download,
                          onTap: () async {
                            final b = _repo.getFileBytes(imgs[cur].url) ?? _repo.getLocalThumb(imgs[cur].url);
                            if (b == null) return;
                            try {
                              final dir  = await getTemporaryDirectory();
                              final path = '${dir.path}/${imgs[cur].name}';
                              final file = io.File(path);
                              await file.writeAsBytes(b, flush: true);
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('Сохранено во временную папку')),
                                );
                              }
                            } catch (_) {}
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // Круглая кнопка в просмотрщике
  Widget _viewerIconButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withOpacity(.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Future<void> _removeSingleImage({required String entryId, required String fileUrl}) async {
    _suppressRealtime = true;
    _pendingDeletedUrls.add(fileUrl);
    if (mounted) setState(() {});
    final updated = await _repo.removeFileFromEntry(entryId: entryId, fileUrl: fileUrl);
    if (updated != null && updated.files.isEmpty && !updated.hasText) {
      await _repo.deleteEntry(updated.id);
      await _loadDay();
      if (mounted) setState(() => _editingEntries.remove(updated.id));
      return;
    }
    if (!_isEditMode) _scheduleReload();
  }

  Future<void> _removeSingleFile({required String entryId, required String fileUrl}) async {
    _suppressRealtime = true;
    _pendingDeletedUrls.add(fileUrl);
    if (mounted) setState(() {});
    final updated = await _repo.removeFileFromEntry(entryId: entryId, fileUrl: fileUrl);
    if (updated != null && updated.files.isEmpty && !updated.hasText) {
      await _repo.deleteEntry(updated.id);
      await _loadDay();
      if (mounted) setState(() => _isEditMode = false);
      return;
    }
    if (!_isEditMode) _scheduleReload();
  }
}

/// ===== нижние листы

class _NewNoteSheet extends StatefulWidget {
  final String subjectKey;
  final SubjectDiaryArgs? args;
  final DateTime date;
  final VoidCallback onSaved;
  const _NewNoteSheet({
    required this.subjectKey,
    this.args,
    required this.date,
    required this.onSaved,
  });

  @override
  State<_NewNoteSheet> createState() => _NewNoteSheetState();
}

class _NewNoteSheetState extends State<_NewNoteSheet> {
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Заметка с пары',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.black),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              maxLines: null,
              minLines: 9,
              decoration: InputDecoration(
                hintText: 'Заметка...',
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width:16, height:16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Сохранить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пустой текст')));
      return;
    }
    setState(() => _saving = true);
    try {
      await SubjectDiaryRepository.instance.addText(
        subjectKey: widget.subjectKey,
        args: widget.args,
        date: widget.date,
        text: text,
      );
      if (!mounted) return;
      widget.onSaved();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _EditNoteSheet extends StatefulWidget {
  final String entryId;
  final String initialText;
  final VoidCallback onSaved;
  const _EditNoteSheet({required this.entryId, required this.initialText, required this.onSaved});

  @override
  State<_EditNoteSheet> createState() => _EditNoteSheetState();
}

class _EditNoteSheetState extends State<_EditNoteSheet> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialText);
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Редактировать заметку',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.black),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              maxLines: null,
              minLines: 9,
              decoration: InputDecoration(
                hintText: 'Текст заметки...',
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width:16, height:16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Сохранить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пустой текст')));
      return;
    }
    setState(() => _saving = true);
    try {
      await SubjectDiaryRepository.instance.updateTextEntry(id: widget.entryId, newText: text);
      if (!mounted) return;
      widget.onSaved();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
