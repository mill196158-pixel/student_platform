part of subject_diary;

/// ===== Экран «Фотографии конспекта»
/// - Шапка по центру, без названия предмета
/// - Везде чёрные шрифты
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
  State<SubjectPhotoConspectScreen> createState() => _SubjectPhotoConspectScreenState();
}

class _SubjectPhotoConspectScreenState extends State<SubjectPhotoConspectScreen> {
  final _picker = ImagePicker();

  // Уже сохранённые за день (read-only превью)
  final _existingThumbs = <_PickedImage>[];

  // Новые, добавляемые в текущем сеансе (можно удалять до сохранения)
  final _newImages = <_PickedImage>[];

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    final repo = SubjectDiaryRepository.instance;
    final all = await repo.listByArgs(
      widget.args ?? SubjectDiaryArgs.legacy(widget.subjectKey),
    );

    _existingThumbs.clear();
    for (final e in all.where((e) =>
        e.date.year == widget.date.year &&
        e.date.month == widget.date.month &&
        e.date.day == widget.date.day &&
        e.hasImages)) {
      for (final f in e.files.where((f) => f.isImage)) {
        final b = repo.getLocalThumb(f.url) ?? repo.getFileBytes(f.url);
        if (b != null) {
          _existingThumbs.add(_PickedImage(name: f.name, mime: 'image/jpeg', bytes: b));
        }
      }
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // локально делаем всю типографику чёрной
    final blackTextTheme = theme.textTheme.apply(bodyColor: Colors.black, displayColor: Colors.black);

    return Theme(
      data: theme.copyWith(textTheme: blackTextTheme),
      child: Scaffold(
        body: Column(
          children: [
            _CenteredHeaderOnlyTitle(title: 'Фотографии конспекта'),
            const SizedBox(height: 8),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadExisting,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 60),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else ...[
                      if (_existingThumbs.isNotEmpty) ...[
                        Text('Уже сохранённые', style: blackTextTheme.labelLarge),
                        const SizedBox(height: 8),
                        _PhotosGrid(
                          images: _existingThumbs,
                          onRemove: (_) {},
                          onOpen: null,
                          editMode: false, // крестиков нет
                        ),
                        const SizedBox(height: 16),
                      ],

                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _pickFromGallery,
                              icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
                              label: const Text('Загрузить'),
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _pickFromCamera,
                              icon: const Icon(Icons.photo_camera_outlined, size: 20),
                              label: const Text('Сделать фото'),
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      if (_newImages.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text('Новых фото пока нет', style: blackTextTheme.bodyMedium),
                          ),
                        )
                      else
                        _PhotosGrid(
                          images: _newImages,
                          onRemove: (i) => setState(() => _newImages.removeAt(i)),
                          editMode: true, // редактируемые до сохранения
                        ),
                      const SizedBox(height: 12),

                      FilledButton.icon(
                        onPressed: _newImages.isEmpty || _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Сохранить конспект'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Новые фото добавятся к уже сохранённым за этот день.',
                        style: blackTextTheme.bodySmall?.copyWith(color: Colors.black54),
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
    final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: 112, // компактнее
      child: Stack(
        fit: StackFit.expand,
        children: [
          // фон как в _ModelHeader
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Colors.white, theme.colorScheme.primary.withOpacity(0.06), theme.colorScheme.primary.withOpacity(0.12)],
                stops: const [0.0, 0.62, 1.0],
              ),
            ),
          ),
          IgnorePointer(
            child: Stack(children: [
              Positioned(left: -40, top: -20, child: _GlowCircle(diameter: 140, color: theme.colorScheme.primary.withOpacity(0.10))),
              Positioned(right: -30, bottom: -30, child: _GlowCircle(diameter: 160, color: Colors.white.withOpacity(0.55))),
            ]),
          ),
          // центрированный заголовок + кнопка назад
          SafeArea(
            bottom: false,
            child: Stack(
              children: [
                const Positioned(left: 16, top: 8, child: _RoundBackButton()),
                // чуть выше центра (без лишнего «проседания»)
                const Align(
                  alignment: Alignment(0, -0.05),
                  child: _TitleText(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Выделил текст в отдельный виджет — так короче и читаемее
class _TitleText extends StatelessWidget {
  const _TitleText();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Фотографии конспекта',
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: Colors.black,
        height: 1.05,
      ),
    );
  }
}
