import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../../shared/widgets/publication_status_badge.dart';
import 'admin_image_picker.dart';
import 'admin_image_store.dart';
import 'news_item.dart';
import 'news_repository.dart';
import 'supabase_admin_image_store.dart';
import 'supabase_news_repository.dart';
import 'widgets/news_image_field.dart';

class NewsEditorScreen extends StatefulWidget {
  const NewsEditorScreen({
    super.key,
    this.repository,
    this.imageStore,
    this.imagePicker,
    this.session,
  });

  final NewsRepository? repository;
  final AdminImageStore? imageStore;
  final AdminImagePicker? imagePicker;
  final AdminSessionController? session;

  @override
  State<NewsEditorScreen> createState() => _NewsEditorScreenState();
}

class _NewsEditorScreenState extends State<NewsEditorScreen> {
  late final NewsRepository _repository = widget.repository ?? _defaultRepo();
  late final AdminImageStore _imageStore = widget.imageStore ?? _defaultStore();
  late final AdminImagePicker _imagePicker =
      widget.imagePicker ?? LocalAdminImagePicker();

  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  final _bodyController = TextEditingController();

  List<NewsItem> _items = [];
  String? _selectedId;
  final Map<String, Uint8List> _resolvedBytes = {};
  final Set<String> _pendingUploadIds = {};

  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  String? _imageError;
  String? _banner;
  String? _loadError;

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  NewsRepository _defaultRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalNewsRepository();
    final client = _tryClient();
    if (client == null) return LocalNewsRepository();
    return SupabaseNewsRepository(client: client);
  }

  AdminImageStore _defaultStore() {
    if (AdminBackendConfig.isDemoMode) return LocalAdminImageStore();
    final client = _tryClient();
    if (client == null) return LocalAdminImageStore();
    return SupabaseAdminImageStore(client: client);
  }

  SupabaseAdminImageStore? get _mediaStore {
    final store = _imageStore;
    return store is SupabaseAdminImageStore ? store : null;
  }

  bool get _canWrite => widget.session?.capabilities.canWriteContent ?? true;
  bool get _canPublish =>
      widget.session?.capabilities.canPublishContent ?? true;

  NewsItem? get _selected {
    if (_selectedId == null) return null;
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final items = await _repository.listNews();
      if (!mounted) return;
      setState(() {
        _items = items;
        _selectedId = items.isNotEmpty ? items.first.id : null;
        _loading = false;
        _loadError = null;
      });
      _syncControllers();
      _resolveRemoteImages();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            'Не удалось загрузить новости. Попробуйте обновить страницу.';
      });
    }
  }

  Future<void> _resolveRemoteImages() async {
    final media = _mediaStore;
    if (media == null) return;
    for (final item in _items) {
      final path = item.imagePath;
      if (path == null || path.isEmpty) continue;
      if (_resolvedBytes.containsKey(item.id)) continue;
      final bytes = await media.resolveBytes(path);
      if (!mounted) return;
      if (bytes != null) {
        setState(() => _resolvedBytes[item.id] = bytes);
      }
    }
  }

  void _syncControllers() {
    final selected = _selected;
    _titleController.value = TextEditingValue(
      text: selected?.title ?? '',
      selection: TextSelection.collapsed(
        offset: (selected?.title ?? '').length,
      ),
    );
    _subtitleController.value = TextEditingValue(
      text: selected?.subtitle ?? '',
      selection: TextSelection.collapsed(
        offset: (selected?.subtitle ?? '').length,
      ),
    );
    _bodyController.value = TextEditingValue(
      text: selected?.body ?? '',
      selection: TextSelection.collapsed(offset: (selected?.body ?? '').length),
    );
    _imageError = null;
  }

  void _select(String id) {
    setState(() => _selectedId = id);
    _syncControllers();
  }

  void _replaceItem(NewsItem item) {
    final index = _items.indexWhere((e) => e.id == item.id);
    if (index >= 0) {
      _items[index] = item;
    }
  }

  void _updateSelected(NewsItem Function(NewsItem item) update) {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      _replaceItem(update(selected));
      _dirty = true;
    });
  }

  Uint8List? _bytesForItem(NewsItem item) {
    final id = item.imageId;
    if (id != null) {
      final bytes = _imageStore.getBytes(id);
      if (bytes != null) return bytes;
    }
    return _resolvedBytes[item.id];
  }

  void _showBanner(String message) {
    setState(() => _banner = message);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<T?> _runGuarded<T>(Future<T> Function() action) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      return await action();
    } on NewsRepositoryException catch (error) {
      _showBanner(error.message);
      return null;
    } catch (_) {
      _showBanner('Не удалось выполнить операцию. Попробуйте ещё раз.');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -- Actions ---------------------------------------------------------------

  Future<void> _create() async {
    if (!_canWrite) {
      _showBanner('Недостаточно прав для создания новостей.');
      return;
    }
    await _runGuarded(() async {
      final created = await _repository.createDraft();
      if (!mounted) return;
      setState(() {
        _items = [..._items, created];
        _selectedId = created.id;
      });
      _syncControllers();
      _snack('Черновик создан');
    });
  }

  Future<void> _duplicate() async {
    final selected = _selected;
    if (selected == null) return;
    if (!_canWrite) {
      _showBanner('Недостаточно прав.');
      return;
    }
    await _runGuarded(() async {
      final copy = await _repository.duplicate(selected.id);
      if (!mounted) return;
      setState(() {
        _items = [..._items, copy];
        _selectedId = copy.id;
      });
      _syncControllers();
      _resolveRemoteImages();
      _snack('Создана копия');
    });
  }

  /// Uploads any pending local image, then persists field edits via updateDraft.
  Future<NewsItem?> _saveSelected() async {
    final selected = _selected;
    if (selected == null) return null;
    var toSave = selected;

    final media = _mediaStore;
    final localId = selected.imageId;
    if (media != null &&
        localId != null &&
        _pendingUploadIds.contains(selected.id)) {
      final path = await media.uploadPending(
        localId,
        previousPath: selected.imagePath,
      );
      toSave = selected.copyWith(imagePath: path);
    }

    final saved = await _repository.updateDraft(toSave);
    if (!mounted) return saved;
    setState(() {
      _replaceItem(saved);
      _pendingUploadIds.remove(saved.id);
      _dirty = false;
    });
    return saved;
  }

  Future<void> _saveDraft() async {
    if (!_canWrite) {
      _showBanner('Недостаточно прав для сохранения.');
      return;
    }
    await _runGuarded(() async {
      final saved = await _saveSelected();
      if (saved != null) _snack('Черновик сохранён');
    });
  }

  Future<void> _publish() async {
    final selected = _selected;
    if (selected == null) return;
    if (!_canPublish) {
      _showBanner('Недостаточно прав для публикации.');
      return;
    }
    await _runGuarded(() async {
      if (_dirty) await _saveSelected();
      final published = await _repository.publish(selected.id);
      if (!mounted) return;
      setState(() => _replaceItem(published));
      _snack('Новость опубликована');
    });
  }

  Future<void> _unpublish() async {
    final selected = _selected;
    if (selected == null) return;
    if (!_canPublish) {
      _showBanner('Недостаточно прав.');
      return;
    }
    await _runGuarded(() async {
      final updated = await _repository.unpublish(selected.id);
      if (!mounted) return;
      setState(() => _replaceItem(updated));
      _snack('Публикация снята');
    });
  }

  Future<void> _archive() async {
    final selected = _selected;
    if (selected == null) return;
    if (!_canWrite) {
      _showBanner('Недостаточно прав.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Отправить в архив?'),
        content: Text('«${selected.title}» скроется из ленты студентов.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('В архив'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runGuarded(() async {
      final updated = await _repository.archive(selected.id);
      if (!mounted) return;
      setState(() => _replaceItem(updated));
      _snack('Новость в архиве');
    });
  }

  Future<void> _move(int delta) async {
    final selected = _selected;
    if (selected == null) return;
    final index = _items.indexWhere((e) => e.id == selected.id);
    final target = index + delta;
    if (target < 0 || target >= _items.length) return;
    setState(() {
      final item = _items.removeAt(index);
      _items.insert(target, item);
    });
    await _runGuarded(() async {
      await _repository.reorder(_items.map((e) => e.id).toList());
    });
  }

  Future<void> _pickImage() async {
    final selected = _selected;
    if (selected == null) return;
    try {
      final picked = await _imagePicker.pickImage();
      if (picked == null) return;
      final previousLocalId = selected.imageId;
      final stored = await _imageStore.put(
        bytes: picked.bytes,
        mimeType: picked.mimeType,
        fileName: picked.fileName,
      );
      if (previousLocalId != null) {
        await _imageStore.remove(previousLocalId);
      }
      if (!mounted) return;
      setState(() {
        _imageError = null;
        _replaceItem(selected.copyWith(imageId: stored.id));
        _pendingUploadIds.add(selected.id);
        _dirty = true;
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
    final selected = _selected;
    if (selected == null) return;
    final previousLocalId = selected.imageId;
    setState(() {
      _replaceItem(selected.copyWith(clearImageId: true, clearImagePath: true));
      _resolvedBytes.remove(selected.id);
      _pendingUploadIds.remove(selected.id);
      _imageError = null;
      _dirty = true;
    });
    if (previousLocalId != null) {
      await _imageStore.remove(previousLocalId);
    }
  }

  Future<void> _showVersions() async {
    final selected = _selected;
    if (selected == null) return;
    final versions = await _runGuarded(
      () => _repository.listVersions(selected.id),
    );
    if (versions == null || !mounted) return;
    if (versions.isEmpty) {
      _snack('История версий пуста');
      return;
    }
    final restore = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _VersionHistoryDialog(versions: versions),
    );
    if (restore == null) return;
    await _runGuarded(() async {
      final restored = await _repository.restoreVersion(selected.id, restore);
      if (!mounted) return;
      setState(() {
        _replaceItem(restored);
        _dirty = false;
      });
      _syncControllers();
      _resolveRemoteImages();
      _snack('Версия $restore восстановлена');
    });
  }

  void _openStoryPreview(List<NewsItem> visible, int index) {
    final news = [
      for (final item in visible)
        item.toPresentation(bytes: _bytesForItem(item)),
    ];
    if (news.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) => StudentNewsStorySheet(news: news, initialIndex: index),
    );
  }

  // -- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return _ErrorState(
        message: _loadError!,
        onRetry: () {
          setState(() => _loading = true);
          _bootstrap();
        },
      );
    }

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmDiscard();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _EditorHeader(
            selected: _selected,
            dirty: _dirty,
            busy: _busy,
            canWrite: _canWrite,
            canPublish: _canPublish,
            banner: _banner,
            onSaveDraft: _saveDraft,
            onPublish: _publish,
            onUnpublish: _unpublish,
            onVersions: _showVersions,
          ),
          const SizedBox(height: 14),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    final navigator = Navigator.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Несохранённые изменения'),
        content: const Text('Выйти без сохранения черновика?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      navigator.maybePop();
    }
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1180;
        final medium = constraints.maxWidth >= 860;
        final visible = _items.where((item) => !item.isHidden).toList();

        final list = _NewsListPanel(
          items: _items,
          selectedId: _selectedId,
          bytesFor: _bytesForItem,
          onSelected: _select,
          onMove: _move,
          onCreate: _canWrite ? _create : null,
        );
        final phone = _PhonePreview(
          items: visible,
          selectedId: _selectedId,
          bytesFor: _bytesForItem,
          onSelected: _select,
          onOpenStory: (index) => _openStoryPreview(visible, index),
        );
        final props = _selected == null
            ? const Card(child: Center(child: Text('Выберите новость')))
            : _PropertiesPanel(
                selected: _selected!,
                imageBytes: _bytesForItem(_selected!),
                imageError: _imageError,
                canWrite: _canWrite,
                titleController: _titleController,
                subtitleController: _subtitleController,
                bodyController: _bodyController,
                onTitleChanged: (value) =>
                    _updateSelected((item) => item.copyWith(title: value)),
                onSubtitleChanged: (value) =>
                    _updateSelected((item) => item.copyWith(subtitle: value)),
                onBodyChanged: (value) =>
                    _updateSelected((item) => item.copyWith(body: value)),
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
                onArchive: _archive,
              );

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 280, child: list),
              const SizedBox(width: 14),
              Expanded(flex: 5, child: phone),
              const SizedBox(width: 14),
              SizedBox(width: 340, child: props),
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
              SizedBox(width: 340, child: props),
            ],
          );
        }
        return ListView(
          children: [
            SizedBox(height: 520, child: phone),
            const SizedBox(height: 12),
            SizedBox(height: 260, child: list),
            const SizedBox(height: 12),
            SizedBox(height: 720, child: props),
          ],
        );
      },
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.selected,
    required this.dirty,
    required this.busy,
    required this.canWrite,
    required this.canPublish,
    required this.banner,
    required this.onSaveDraft,
    required this.onPublish,
    required this.onUnpublish,
    required this.onVersions,
  });

  final NewsItem? selected;
  final bool dirty;
  final bool busy;
  final bool canWrite;
  final bool canPublish;
  final String? banner;
  final VoidCallback onSaveDraft;
  final VoidCallback onPublish;
  final VoidCallback onUnpublish;
  final VoidCallback onVersions;

  @override
  Widget build(BuildContext context) {
    final status = selected?.status ?? NewsStatus.draft;
    final isPublished = status == NewsStatus.published;
    final isArchived = status == NewsStatus.archived;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(
              'Визуальный редактор новостей',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (selected != null)
              PublicationStatusBadge(status: status.russianLabel),
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: (busy || !canWrite || isArchived) ? null : onSaveDraft,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Сохранить черновик'),
            ),
            OutlinedButton.icon(
              onPressed: (busy || selected == null) ? null : onVersions,
              icon: const Icon(Icons.history_rounded),
              label: const Text('История версий'),
            ),
            if (isPublished)
              FilledButton.tonalIcon(
                onPressed: (busy || !canPublish) ? null : onUnpublish,
                icon: const Icon(Icons.unpublished_outlined),
                label: const Text('Снять с публикации'),
              )
            else
              FilledButton.icon(
                onPressed: (busy || !canPublish || isArchived)
                    ? null
                    : onPublish,
                icon: const Icon(Icons.publish_outlined),
                label: const Text('Опубликовать'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (banner != null)
          _Banner(
            color: const Color(0xFFFDE7E9),
            border: const Color(0xFFF3B4BB),
            icon: Icons.error_outline,
            iconColor: const Color(0xFFB3261E),
            textColor: const Color(0xFF8C1D18),
            text: banner!,
          )
        else
          _Banner(
            color: const Color(0xFFEFF4FF),
            border: const Color(0xFFC7D6F5),
            icon: Icons.info_outline,
            iconColor: const Color(0xFF2F5AA8),
            textColor: const Color(0xFF2F5AA8),
            text: dirty
                ? 'Есть несохранённые изменения. Сохраните черновик, чтобы не потерять правки.'
                : 'Изменения сохраняются на сервере. Публикация видна студентам сразу.',
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.border,
    required this.icon,
    required this.iconColor,
    required this.textColor,
    required this.text,
  });

  final Color color;
  final Color border;
  final IconData icon;
  final Color iconColor;
  final Color textColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewsListPanel extends StatelessWidget {
  const _NewsListPanel({
    required this.items,
    required this.selectedId,
    required this.bytesFor,
    required this.onSelected,
    required this.onMove,
    required this.onCreate,
  });

  final List<NewsItem> items;
  final String? selectedId;
  final Uint8List? Function(NewsItem item) bytesFor;
  final ValueChanged<String> onSelected;
  final ValueChanged<int> onMove;
  final VoidCallback? onCreate;

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
                  onPressed:
                      selectedIndex >= 0 && selectedIndex < items.length - 1
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
              child: items.isEmpty
                  ? const Center(child: Text('Пока нет новостей'))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final isSelected = item.id == selectedId;
                        final bytes = bytesFor(item);
                        return Material(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
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
                              '${item.variant.russianLabel} · ${item.status.russianLabel}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: item.isHidden
                                ? const Icon(
                                    Icons.visibility_off_outlined,
                                    size: 18,
                                  )
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
    required this.bytesFor,
    required this.onSelected,
    required this.onOpenStory,
  });

  final List<NewsItem> items;
  final String? selectedId;
  final Uint8List? Function(NewsItem item) bytesFor;
  final ValueChanged<String> onSelected;
  final ValueChanged<int> onOpenStory;

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
            for (final item in items)
              item.toPresentation(bytes: bytesFor(item)),
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
                            selectedNewsId: selectedId == null
                                ? null
                                : 'admin-news-$selectedId',
                            adminNewsHighlightColor: const Color(0xFF6656D9),
                            onNewsTap: (index) {
                              if (index >= 0 && index < items.length) {
                                onSelected(items[index].id);
                                onOpenStory(index);
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
    required this.canWrite,
    required this.titleController,
    required this.subtitleController,
    required this.bodyController,
    required this.onTitleChanged,
    required this.onSubtitleChanged,
    required this.onBodyChanged,
    required this.onVariantChanged,
    required this.onVisibilityChanged,
    required this.onImageFocusChanged,
    required this.onOverlayChanged,
    required this.onPickImage,
    required this.onClearImage,
    required this.onDuplicate,
    required this.onArchive,
  });

  final NewsItem selected;
  final Uint8List? imageBytes;
  final String? imageError;
  final bool canWrite;
  final TextEditingController titleController;
  final TextEditingController subtitleController;
  final TextEditingController bodyController;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onSubtitleChanged;
  final ValueChanged<String> onBodyChanged;
  final ValueChanged<StudentHomeNewsVariant> onVariantChanged;
  final ValueChanged<bool> onVisibilityChanged;
  final ValueChanged<Alignment> onImageFocusChanged;
  final ValueChanged<double> onOverlayChanged;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onDuplicate;
  final VoidCallback onArchive;

  static const _focusOptions = <(String, Alignment)>[
    ('Центр', Alignment.center),
    ('Верх', Alignment.topCenter),
    ('Низ', Alignment.bottomCenter),
    ('Лево', Alignment.centerLeft),
    ('Право', Alignment.centerRight),
  ];

  @override
  Widget build(BuildContext context) {
    final enabled = canWrite && !selected.isArchived;
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
            enabled: enabled,
            onChanged: onTitleChanged,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Заголовок'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: subtitleController,
            enabled: enabled,
            onChanged: onSubtitleChanged,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Подзаголовок'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: bodyController,
            enabled: enabled,
            onChanged: onBodyChanged,
            maxLines: 6,
            minLines: 3,
            decoration: const InputDecoration(
              labelText: 'Текст новости',
              alignLabelWithHint: true,
            ),
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
            onChanged: enabled
                ? (value) {
                    if (value != null) onVariantChanged(value);
                  }
                : null,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Временно скрыть'),
            subtitle: const Text('Карточка исчезнет из предпросмотра и ленты'),
            value: selected.isHidden,
            onChanged: enabled ? onVisibilityChanged : null,
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
                    onSelected: enabled
                        ? (_) => onImageFocusChanged(option.$2)
                        : null,
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
                onChanged: enabled ? onOverlayChanged : null,
              ),
            ],
          ],
          const Divider(height: 28),
          OutlinedButton.icon(
            onPressed: canWrite ? onDuplicate : null,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Дублировать'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: (canWrite && !selected.isArchived) ? onArchive : null,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('В архив'),
          ),
        ],
      ),
    );
  }
}

class _VersionHistoryDialog extends StatelessWidget {
  const _VersionHistoryDialog({required this.versions});

  final List<NewsVersionInfo> versions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('История версий'),
      content: SizedBox(
        width: 380,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: versions.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final version = versions[index];
            final subtitleParts = <String>[
              if (version.title.isNotEmpty) version.title,
              if (version.status != null) version.status!.russianLabel,
            ];
            return ListTile(
              leading: CircleAvatar(child: Text('${version.versionNumber}')),
              title: Text('Версия ${version.versionNumber}'),
              subtitle: subtitleParts.isEmpty
                  ? null
                  : Text(
                      subtitleParts.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(version.versionNumber),
                child: const Text('Восстановить'),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}
