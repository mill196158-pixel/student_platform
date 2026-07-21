import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'admin_image_picker.dart';
import 'admin_image_store.dart';
import 'news_item.dart';
import 'news_repository.dart';
import 'widgets/news_image_field.dart';

class NewsEditorScreen extends StatefulWidget {
  const NewsEditorScreen({
    super.key,
    this.repository,
    this.imageStore,
    this.imagePicker,
  });

  final NewsRepository? repository;
  final AdminImageStore? imageStore;
  final AdminImagePicker? imagePicker;

  @override
  State<NewsEditorScreen> createState() => _NewsEditorScreenState();
}

class _NewsEditorScreenState extends State<NewsEditorScreen> {
  late final NewsRepository _repository =
      widget.repository ?? LocalNewsRepository();
  late final AdminImageStore _imageStore =
      widget.imageStore ?? LocalAdminImageStore();
  late final AdminImagePicker _imagePicker =
      widget.imagePicker ?? LocalAdminImagePicker();

  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();

  List<NewsItem> _items = [];
  int _selectedId = 1;
  int _nextId = 5;
  DateTime? _draftSavedAt;
  bool _dirty = false;
  String? _imageError;
  bool _loading = true;

  static const _palette = <List<Color>>[
    [Color(0xFF7367F0), Color(0xFFB784F7)],
    [Color(0xFF246B8E), Color(0xFF54B7AD)],
    [Color(0xFFF3A95F), Color(0xFFE66E75)],
    [Color(0xFF4158D0), Color(0xFFC850C0)],
    [Color(0xFF2F9D84), Color(0xFF7C63D8)],
  ];

  NewsItem get _selected => _items.firstWhere((item) => item.id == _selectedId);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final items = await _repository.loadDraft();
    if (!mounted) return;
    setState(() {
      _items = items;
      _selectedId = items.first.id;
      _nextId = items.map((e) => e.id).fold<int>(0, math.max) + 1;
      _loading = false;
    });
    _syncControllers();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    super.dispose();
  }

  void _syncControllers() {
    final selected = _selected;
    _titleController.value = TextEditingValue(
      text: selected.title,
      selection: TextSelection.collapsed(offset: selected.title.length),
    );
    _subtitleController.value = TextEditingValue(
      text: selected.subtitle,
      selection: TextSelection.collapsed(offset: selected.subtitle.length),
    );
    _imageError = null;
  }

  void _select(int id) {
    setState(() => _selectedId = id);
    _syncControllers();
  }

  void _markDirty() {
    _dirty = true;
  }

  void _updateSelected(NewsItem Function(NewsItem item) update) {
    final index = _items.indexWhere((item) => item.id == _selectedId);
    setState(() {
      _items[index] = update(_items[index]);
      _markDirty();
    });
  }

  void _create() {
    final item = NewsItem(
      id: _nextId++,
      title: 'Новая новость',
      subtitle: 'Краткое описание',
      variant: StudentHomeNewsVariant.gradientText,
      colors: _palette[_items.length % _palette.length],
    );
    setState(() {
      _items.insert(0, item);
      _selectedId = item.id;
      _markDirty();
    });
    _syncControllers();
  }

  Future<void> _duplicate() async {
    final source = _selected;
    var imageId = source.imageId;
    if (imageId != null) {
      final bytes = _imageStore.getBytes(imageId);
      final mime = _imageStore.mimeTypeOf(imageId) ?? 'image/png';
      if (bytes != null) {
        final stored = await _imageStore.put(
          bytes: bytes,
          mimeType: mime,
          fileName: 'copy-$imageId',
        );
        imageId = stored.id;
      }
    }
    final copy = source.copyWith(
      id: _nextId++,
      title: '${source.title} — копия',
      isHidden: false,
      imageId: imageId,
    );
    final index = _items.indexOf(source);
    if (!mounted) return;
    setState(() {
      _items.insert(index + 1, copy);
      _selectedId = copy.id;
      _markDirty();
    });
    _syncControllers();
  }

  Future<void> _delete() async {
    if (_items.length == 1) return;
    final index = _items.indexWhere((item) => item.id == _selectedId);
    final deleted = _items[index];
    setState(() {
      _items.removeAt(index);
      _selectedId = _items[index.clamp(0, _items.length - 1)].id;
      _markDirty();
    });
    _syncControllers();

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('«${deleted.title}» удалена'),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () {
              setState(() {
                _items.insert(index, deleted);
                _selectedId = deleted.id;
                _markDirty();
              });
              _syncControllers();
            },
          ),
        ),
      );
  }

  void _move(int delta) {
    final index = _items.indexWhere((item) => item.id == _selectedId);
    final target = index + delta;
    if (target < 0 || target >= _items.length) return;
    setState(() {
      final item = _items.removeAt(index);
      _items.insert(target, item);
      _markDirty();
    });
  }

  Future<void> _saveDraft() async {
    await _repository.saveDraft(_items);
    if (!mounted) return;
    setState(() {
      _draftSavedAt = DateTime.now();
      _dirty = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Черновик сохранён локально')));
  }

  Future<void> _pickImage() async {
    try {
      final picked = await _imagePicker.pickImage();
      if (picked == null) return;
      final previousId = _selected.imageId;
      final stored = await _imageStore.put(
        bytes: picked.bytes,
        mimeType: picked.mimeType,
        fileName: picked.fileName,
      );
      if (previousId != null) {
        await _imageStore.remove(previousId);
      }
      if (!mounted) return;
      final index = _items.indexWhere((item) => item.id == _selectedId);
      setState(() {
        _imageError = null;
        _items[index] = _items[index].copyWith(imageId: stored.id);
        _markDirty();
      });
    } on AdminImagePickException catch (error) {
      if (!mounted) return;
      setState(() => _imageError = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _imageError =
            'Не удалось выбрать изображение. Попробуйте другой файл.',
      );
    }
  }

  Future<void> _clearImage() async {
    final previousId = _selected.imageId;
    final index = _items.indexWhere((item) => item.id == _selectedId);
    setState(() {
      _items[index] = _items[index].copyWith(clearImageId: true);
      _imageError = null;
      _markDirty();
    });
    if (previousId != null) {
      await _imageStore.remove(previousId);
    }
  }

  Uint8List? _bytesFor(NewsItem item) {
    final id = item.imageId;
    if (id == null) return null;
    return _imageStore.getBytes(id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EditorHeader(
          dirty: _dirty,
          draftSavedAt: _draftSavedAt,
          onSaveDraft: _saveDraft,
        ),
        const SizedBox(height: 14),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 1180;
              final medium = constraints.maxWidth >= 860;

              final list = _NewsListPanel(
                items: _items,
                selectedId: _selectedId,
                imageStore: _imageStore,
                onSelected: _select,
                onMove: _move,
                onCreate: _create,
              );
              final phone = _PhonePreview(
                items: _items.where((item) => !item.isHidden).toList(),
                selectedId: _selectedId,
                imageStore: _imageStore,
                onSelected: _select,
              );
              final props = _PropertiesPanel(
                selected: _selected,
                imageBytes: _bytesFor(_selected),
                imageError: _imageError,
                titleController: _titleController,
                subtitleController: _subtitleController,
                onTitleChanged: (value) =>
                    _updateSelected((item) => item.copyWith(title: value)),
                onSubtitleChanged: (value) =>
                    _updateSelected((item) => item.copyWith(subtitle: value)),
                onVariantChanged: (value) =>
                    _updateSelected((item) => item.copyWith(variant: value)),
                onVisibilityChanged: (value) =>
                    _updateSelected((item) => item.copyWith(isHidden: value)),
                onImageFocusChanged: (value) =>
                    _updateSelected((item) => item.copyWith(imageFocus: value)),
                onOverlayChanged: (value) => _updateSelected(
                  (item) => item.copyWith(overlayDarken: value),
                ),
                onPickImage: _pickImage,
                onClearImage: _clearImage,
                onDuplicate: _duplicate,
                onDelete: _delete,
                canDelete: _items.length > 1,
              );

              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 280, child: list),
                    const SizedBox(width: 14),
                    Expanded(flex: 5, child: phone),
                    const SizedBox(width: 14),
                    SizedBox(width: 320, child: props),
                  ],
                );
              }

              if (medium) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        children: [
                          Expanded(flex: 5, child: phone),
                          const SizedBox(height: 12),
                          SizedBox(height: 220, child: list),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(width: 320, child: props),
                  ],
                );
              }

              return ListView(
                children: [
                  SizedBox(height: 520, child: phone),
                  const SizedBox(height: 12),
                  SizedBox(height: 260, child: list),
                  const SizedBox(height: 12),
                  SizedBox(height: 640, child: props),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.dirty,
    required this.draftSavedAt,
    required this.onSaveDraft,
  });

  final bool dirty;
  final DateTime? draftSavedAt;
  final VoidCallback onSaveDraft;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Визуальный редактор новостей',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onSaveDraft,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Сохранить черновик'),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message:
                  'Публикация станет доступна после настройки безопасного доступа',
              child: FilledButton.icon(
                onPressed: null,
                icon: const Icon(Icons.publish_outlined),
                label: const Text('Опубликовать'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFFFF4E5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFFD9A8)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Color(0xFF9A6700)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    dirty
                        ? 'Локальный черновик изменён. Публикация пока недоступна до подключения безопасного доступа.'
                        : 'Локальный черновик. Публикация пока недоступна до подключения безопасного доступа.',
                    style: const TextStyle(
                      color: Color(0xFF7A5200),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (draftSavedAt case final savedAt?)
                  Text(
                    'Сохранено ${savedAt.hour.toString().padLeft(2, '0')}:${savedAt.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Color(0xFF4E8B68)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NewsListPanel extends StatelessWidget {
  const _NewsListPanel({
    required this.items,
    required this.selectedId,
    required this.imageStore,
    required this.onSelected,
    required this.onMove,
    required this.onCreate,
  });

  final List<NewsItem> items;
  final int selectedId;
  final AdminImageStore imageStore;
  final ValueChanged<int> onSelected;
  final ValueChanged<int> onMove;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = items.indexWhere((item) => item.id == selectedId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Новости',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Выше',
                  onPressed: selectedIndex > 0 ? () => onMove(-1) : null,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
                IconButton(
                  tooltip: 'Ниже',
                  onPressed: selectedIndex < items.length - 1
                      ? () => onMove(1)
                      : null,
                  icon: const Icon(Icons.arrow_downward_rounded),
                ),
                IconButton.filledTonal(
                  tooltip: 'Создать',
                  onPressed: onCreate,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isSelected = item.id == selectedId;
                  final bytes = item.imageId == null
                      ? null
                      : imageStore.getBytes(item.imageId!);
                  return Material(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    child: ListTile(
                      selected: isSelected,
                      onTap: () => onSelected(item.id),
                      leading: _ListThumb(
                        index: index,
                        bytes: bytes,
                        colors: item.colors,
                      ),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.variant.russianLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: item.isHidden
                          ? const Icon(Icons.visibility_off_outlined, size: 18)
                          : Text(
                              '${index + 1}',
                              style: const TextStyle(
                                color: Color(0xFF6E7180),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListThumb extends StatelessWidget {
  const _ListThumb({
    required this.index,
    required this.bytes,
    required this.colors,
  });

  final int index;
  final Uint8List? bytes;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(colors: colors),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null || bytes!.isEmpty
          ? Center(
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            )
          : Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

class _PhonePreview extends StatelessWidget {
  const _PhonePreview({
    required this.items,
    required this.selectedId,
    required this.imageStore,
    required this.onSelected,
  });

  final List<NewsItem> items;
  final int selectedId;
  final AdminImageStore imageStore;
  final ValueChanged<int> onSelected;

  static const _designWidth = 390.0;
  static const _designHeight = 844.0;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFE9EAF1),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = math.max(0.0, constraints.maxWidth - 24);
          final availableHeight = math.max(0.0, constraints.maxHeight - 24);
          final scale = math
              .min(
                availableWidth / _designWidth,
                availableHeight / _designHeight,
              )
              .clamp(0.35, 1.0);
          final now = DateTime.now();
          final presentationNews = [
            for (final item in items) item.toPresentation(imageStore),
          ];
          final previewData = StudentHomeData(
            profile: const StudentHomeProfile(
              name: 'Минь',
              groupName: '1-См(ВВ)-2',
            ),
            currentDate: now,
            lessons: const [
              StudentHomeLesson(
                subject: 'Базы данных',
                start: TimeOfDay(hour: 10, minute: 0),
                pairNumber: 2,
                room: '203',
                teacher: 'М. С. Лебедев',
              ),
              StudentHomeLesson(
                subject: 'Информационная безопасность',
                start: TimeOfDay(hour: 12, minute: 0),
                pairNumber: 3,
                room: '410',
                teacher: 'О. А. Морозова',
              ),
            ],
            assignments: const [
              StudentHomeAssignment(
                id: 'preview-assignment-1',
                title: 'Подготовить отчёт по лабораторной работе',
                subject: 'Базы данных',
                deadline: '23 июл.',
              ),
              StudentHomeAssignment(
                id: 'preview-assignment-2',
                title: 'Повторить материалы к семинару',
                subject: 'Информационная безопасность',
                deadline: '25 июл.',
                status: StudentHomeAssignmentStatus.inProgress,
              ),
            ],
            news: presentationNews,
            totalLessonsToday: 2,
            assignmentsCount: 2,
          );

          return Center(
            child: SizedBox(
              width: _designWidth * scale,
              height: _designHeight * scale,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Container(
                  width: _designWidth,
                  height: _designHeight,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7FB),
                    borderRadius: BorderRadius.circular(42),
                    border: Border.all(
                      color: const Color(0xFF242536),
                      width: 8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 24,
                        color: Color(0x22000000),
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Theme(
                    data: studentPlatformLightTheme(),
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: const Size(_designWidth - 16, _designHeight - 16),
                        padding: const EdgeInsets.only(top: 24),
                        viewPadding: const EdgeInsets.only(top: 24),
                        textScaler: TextScaler.noScaling,
                      ),
                      child: Stack(
                        children: [
                          StudentHomeView(
                            data: previewData,
                            notificationCount: 3,
                            selectedNewsId: 'admin-news-$selectedId',
                            adminNewsHighlightColor: const Color(0xFF6656D9),
                            onNewsTap: (index) {
                              if (index >= 0 && index < items.length) {
                                onSelected(items[index].id);
                              }
                            },
                            bottomNavigationBar: StudentBottomNav(
                              currentIndex: 0,
                              items: studentBottomNavItems,
                              onTap: (_) {},
                            ),
                          ),
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(child: _PhoneSystemBar()),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PhoneSystemBar extends StatelessWidget {
  const _PhoneSystemBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Container(
            width: 108,
            height: 22,
            decoration: const BoxDecoration(
              color: Color(0xFF242536),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PropertiesPanel extends StatelessWidget {
  const _PropertiesPanel({
    required this.selected,
    required this.imageBytes,
    required this.imageError,
    required this.titleController,
    required this.subtitleController,
    required this.onTitleChanged,
    required this.onSubtitleChanged,
    required this.onVariantChanged,
    required this.onVisibilityChanged,
    required this.onImageFocusChanged,
    required this.onOverlayChanged,
    required this.onPickImage,
    required this.onClearImage,
    required this.onDuplicate,
    required this.onDelete,
    required this.canDelete,
  });

  final NewsItem selected;
  final Uint8List? imageBytes;
  final String? imageError;
  final TextEditingController titleController;
  final TextEditingController subtitleController;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onSubtitleChanged;
  final ValueChanged<StudentHomeNewsVariant> onVariantChanged;
  final ValueChanged<bool> onVisibilityChanged;
  final ValueChanged<Alignment> onImageFocusChanged;
  final ValueChanged<double> onOverlayChanged;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final bool canDelete;

  static const _focusOptions = <(String, Alignment)>[
    ('Центр', Alignment.center),
    ('Верх', Alignment.topCenter),
    ('Низ', Alignment.bottomCenter),
    ('Лево', Alignment.centerLeft),
    ('Право', Alignment.centerRight),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Свойства карточки',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: titleController,
            onChanged: onTitleChanged,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Заголовок'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: subtitleController,
            onChanged: onSubtitleChanged,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Подзаголовок'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<StudentHomeNewsVariant>(
            key: ValueKey('variant-${selected.id}-${selected.variant}'),
            initialValue: selected.variant,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Вариант карточки'),
            items: [
              for (final variant in StudentHomeNewsVariant.values)
                DropdownMenuItem(
                  value: variant,
                  child: Text(
                    variant.russianLabel,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) onVariantChanged(value);
            },
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Временно скрыть'),
            subtitle: const Text('Карточка исчезнет из предпросмотра'),
            value: selected.isHidden,
            onChanged: onVisibilityChanged,
          ),
          if (selected.usesImage) ...[
            const Divider(height: 28),
            NewsImageField(
              imageBytes: imageBytes,
              errorText: imageError,
              onPick: onPickImage,
              onClear: onClearImage,
            ),
            const SizedBox(height: 16),
            const Text(
              'Положение изображения',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in _focusOptions)
                  ChoiceChip(
                    label: Text(option.$1),
                    selected: selected.imageFocus == option.$2,
                    onSelected: (_) => onImageFocusChanged(option.$2),
                  ),
              ],
            ),
            if (selected.variant == StudentHomeNewsVariant.imageOverlay) ...[
              const SizedBox(height: 16),
              Text(
                'Затемнение текста: ${(selected.overlayDarken * 100).round()}%',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Slider(
                value: selected.overlayDarken.clamp(0.15, 0.85),
                min: 0.15,
                max: 0.85,
                divisions: 14,
                label: '${(selected.overlayDarken * 100).round()}%',
                onChanged: onOverlayChanged,
              ),
            ],
          ],
          const Divider(height: 28),
          OutlinedButton.icon(
            onPressed: onDuplicate,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Дублировать'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: canDelete ? onDelete : null,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}
