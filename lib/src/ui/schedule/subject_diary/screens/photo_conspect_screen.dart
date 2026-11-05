part of subject_diary;

/// ===== Экран «Фотографии конспекта»
/// - Шапка по центру, без названия предмета
/// - Сверху показываем уже сохранённые фото (read-only)
/// - Ниже — новые фото (редактируемые), которые можно дозагрузить и сохранить

class SubjectPhotoConspectScreen extends StatefulWidget {
  final String subjectKey;
  final SubjectDiaryArgs? args;
  final DateTime date;
  const SubjectPhotoConspectScreen({
    super.key,
    required this.subjectKey,
    this.args,
    required this.date,
  });

  @override
  State<SubjectPhotoConspectScreen> createState() =>
      _SubjectPhotoConspectScreenState();
}

class _SubjectPhotoConspectScreenState
    extends State<SubjectPhotoConspectScreen> {
  final _picker = ImagePicker();

  // Уже сохранённые за день (read-only превью)
  final _existingThumbs = <_PickedImage>[];

  // Новые, добавляемые в текущем сеансе (можно удалять до сохранения)
  final _newImages = <_PickedImage>[];

  bool _loading = true;
  bool _loadError = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      final repo = SubjectDiaryRepository.instance;
      final all = await repo.listByArgs(
        widget.args ?? SubjectDiaryArgs.legacy(widget.subjectKey),
      );

      if (!mounted) return;
      _existingThumbs.clear();
      for (final e in all.where((e) =>
          e.date.year == widget.date.year &&
          e.date.month == widget.date.month &&
          e.date.day == widget.date.day &&
          e.hasImages)) {
        for (final f in e.files.where((f) => f.isImage)) {
          final b = repo.getLocalThumb(f.url) ?? repo.getFileBytes(f.url);
          if (b != null) {
            _existingThumbs
                .add(_PickedImage(name: f.name, mime: 'image/jpeg', bytes: b));
          }
        }
      }
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Use the shared light/dark typography.
    final contentTextTheme = theme.textTheme;

    return Theme(
      data: theme.copyWith(textTheme: contentTextTheme),
      child: Scaffold(
        body: Column(
          children: [
            _CenteredHeaderOnlyTitle(title: 'Фотографии конспекта'),
            const SizedBox(height: 8),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadExisting,
                child: ListView(
                  padding: EdgeInsets.symmetric(
                      vertical: 24,
                      horizontal: ((MediaQuery.sizeOf(context).width - 800) / 2)
                          .clamp(16.0, double.infinity)),
                  children: [
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 60),
                        child: Center(child: ProductLoadingIndicator.page()),
                      )
                    else ...[
                      if (_loadError) ...[
                        const Text(
                            'Не удалось загрузить сохранённые фотографии'),
                        OutlinedButton.icon(
                            onPressed: _loadExisting,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Повторить')),
                        const SizedBox(height: 16),
                      ],
                      if (_existingThumbs.isNotEmpty) ...[
                        Text('Уже сохранённые',
                            style: contentTextTheme.labelLarge),
                        const SizedBox(height: 8),
                        _PhotosGrid(
                          images: _existingThumbs,
                          onRemove: (_) {},
                          onOpen: null,
                          editMode: false, // крестиков нет
                        ),
                        const SizedBox(height: 16),
                      ],
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            child: FilledButton.tonalIcon(
                              onPressed: _pickFromGallery,
                              icon: const Icon(
                                  Icons.add_photo_alternate_outlined,
                                  size: 20),
                              label: const Text('Загрузить'),
                              style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            child: FilledButton.tonalIcon(
                              onPressed: _pickFromCamera,
                              icon: const Icon(Icons.photo_camera_outlined,
                                  size: 20),
                              label: const Text('Сделать фото'),
                              style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_newImages.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text('Новых фото пока нет',
                                style: contentTextTheme.bodyMedium),
                          ),
                        )
                      else
                        _PhotosGrid(
                          images: _newImages,
                          onRemove: (i) =>
                              setState(() => _newImages.removeAt(i)),
                          editMode: true, // редактируемые до сохранения
                        ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _newImages.isEmpty || _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    ProductLoadingIndicator())
                            : const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Сохранить конспект'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Новые фото добавятся к уже сохранённым за этот день.',
                        style: contentTextTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    final list = await _picker.pickMultiImage(imageQuality: 85);
    if (list == null || list.isEmpty) return;
    for (final x in list) {
      final bytes = await x.readAsBytes();
      _newImages.add(_PickedImage(
        name: x.name,
        mime: 'image/${x.path.toLowerCase().endsWith('.png') ? 'png' : 'jpeg'}',
        bytes: bytes,
      ));
    }
    setState(() {});
  }

  Future<void> _pickFromCamera() async {
    final x =
        await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() {
      _newImages.add(_PickedImage(
        name: x.name,
        mime: 'image/${x.path.toLowerCase().endsWith('.png') ? 'png' : 'jpeg'}',
        bytes: bytes,
      ));
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Сохраняем только новые — репозиторий добавит их в пул этого дня
      await SubjectDiaryRepository.instance.addConspect(
        subjectKey: widget.subjectKey,
        args: widget.args,
        date: widget.date,
        images: _newImages,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// --- Локальная компактная шапка: только центрированный заголовок
class _CenteredHeaderOnlyTitle extends StatelessWidget {
  final String title;
  const _CenteredHeaderOnlyTitle({required this.title});
  @override
  Widget build(BuildContext context) => WorkspacePageHeader(title: title);
}
