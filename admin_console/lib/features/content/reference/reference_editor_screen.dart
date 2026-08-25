import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../../shared/widgets/admin_student_phone_frame.dart';
import '../../academic/students/students_repository.dart';
import '../profile_feed/content_audience_selectors.dart';
import 'content_media_store.dart';
import 'reference_item.dart';
import 'reference_repository.dart';
import 'supabase_reference_repository.dart';

/// Admin editor for reference articles (`reference_article_v1`, schema 2).
class ReferenceEditorScreen extends StatefulWidget {
  const ReferenceEditorScreen({super.key, this.repository, this.session});

  final ReferenceRepository? repository;
  final AdminSessionController? session;

  @override
  State<ReferenceEditorScreen> createState() => _ReferenceEditorScreenState();
}

class _ReferenceEditorScreenState extends State<ReferenceEditorScreen> {
  late final ReferenceRepository _repository =
      widget.repository ?? _defaultRepo();

  final _titleController = TextEditingController();
  final _iconKeyController = TextEditingController(text: 'help');
  final _shortTextController = TextEditingController();
  final _sortOrderController = TextEditingController(text: '0');

  List<ReferenceBlock> _blocks = [
    const ReferenceTextBlock(text: 'Текст статьи'),
  ];

  List<ReferenceCategoryItem> _categories = [];
  List<ReferenceArticleItem> _articles = [];
  List<ReferenceCorrectionItem> _corrections = [];
  String? _selectedArticleId;
  String? _selectedCategoryId;
  bool _loading = true;
  bool _busy = false;
  String _audienceMode = 'all';
  List<String> _groupIds = const [];
  List<String> _userIds = const [];
  String? _banner;
  String? _loadError;
  late final StudentsRepository _studentsRepository = _defaultStudentsRepo();

  ReferenceArticleItem? get _selectedArticle {
    for (final item in _articles) {
      if (item.id == _selectedArticleId) return item;
    }
    return null;
  }

  bool get _canWrite =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canWriteContent;

  bool get _canPublish =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canPublishContent;

  ReferenceRepository _defaultRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalReferenceRepository();
    final client = _tryClient();
    if (client == null) return LocalReferenceRepository();
    return SupabaseReferenceRepository(client: client);
  }

  StudentsRepository _defaultStudentsRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalStudentsRepository();
    final client = _tryClient();
    if (client == null) return LocalStudentsRepository();
    return SupabaseStudentsRepository(client: client);
  }

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _iconKeyController.dispose();
    _shortTextController.dispose();
    _sortOrderController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final categories = await _repository.listCategories();
      final articles = await _repository.listArticles();
      final corrections = await _repository.listCorrections();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _articles = articles;
        _corrections = corrections;
        _selectedArticleId ??= articles.isEmpty ? null : articles.first.id;
        _selectedCategoryId ??= categories.isEmpty ? null : categories.first.id;
        _loading = false;
      });
      final selected = _selectedArticle;
      if (selected != null) _bindArticle(selected);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _manageCategories() async {
    final titleController = TextEditingController();
    final iconController = TextEditingController(text: 'help');
    final keyController = TextEditingController();
    var working = List<ReferenceCategoryItem>.from(_categories);

    Future<void> editCategory(
      void Function(void Function()) setDialogState,
      int index,
    ) async {
      final current = working[index];
      final editTitle = TextEditingController(text: current.title);
      final editIcon = TextEditingController(text: current.iconKey);
      var status = current.status;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setEditState) {
              return AlertDialog(
                title: Text(
                  current.id.isEmpty ? 'Новая категория' : 'Редактировать',
                ),
                content: SizedBox(
                  width: 360,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: editTitle,
                        decoration: const InputDecoration(
                          labelText: 'Название',
                        ),
                      ),
                      TextField(
                        controller: editIcon,
                        decoration: const InputDecoration(
                          labelText: 'icon_key',
                        ),
                      ),
                      DropdownButtonFormField<ReferenceCategoryStatus>(
                        value: status,
                        decoration: const InputDecoration(labelText: 'Статус'),
                        items: [
                          for (final s in ReferenceCategoryStatus.values)
                            DropdownMenuItem(value: s, child: Text(s.name)),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setEditState(() => status = value);
                        },
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('OK'),
                  ),
                ],
              );
            },
          );
        },
      );
      final nextTitle = editTitle.text.trim();
      final nextIcon = editIcon.text.trim();
      editTitle.dispose();
      editIcon.dispose();
      if (ok != true || nextTitle.isEmpty || nextIcon.isEmpty) return;
      setDialogState(() {
        working = [...working];
        working[index] = current.copyWith(
          title: nextTitle,
          iconKey: nextIcon,
          status: status,
        );
      });
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Категории справочника'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < working.length; i++)
                      ListTile(
                        dense: true,
                        title: Text(working[i].title),
                        subtitle: Text(
                          '${working[i].iconKey} · ${working[i].status.name}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Редактировать / статус',
                              onPressed: () => editCategory(setDialogState, i),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            PopupMenuButton<ReferenceCategoryStatus>(
                              tooltip: 'Статус',
                              onSelected: (status) {
                                setDialogState(() {
                                  working = [...working];
                                  working[i] = working[i].copyWith(
                                    status: status,
                                  );
                                });
                              },
                              itemBuilder: (context) => [
                                for (final s in ReferenceCategoryStatus.values)
                                  PopupMenuItem(value: s, child: Text(s.name)),
                              ],
                              child: const Icon(Icons.flag_outlined),
                            ),
                            IconButton(
                              tooltip: 'Выше',
                              onPressed: i == 0
                                  ? null
                                  : () {
                                      setDialogState(() {
                                        final item = working.removeAt(i);
                                        working.insert(i - 1, item);
                                      });
                                    },
                              icon: const Icon(Icons.arrow_upward),
                            ),
                            IconButton(
                              tooltip: 'Ниже',
                              onPressed: i >= working.length - 1
                                  ? null
                                  : () {
                                      setDialogState(() {
                                        final item = working.removeAt(i);
                                        working.insert(i + 1, item);
                                      });
                                    },
                              icon: const Icon(Icons.arrow_downward),
                            ),
                          ],
                        ),
                      ),
                    const Divider(),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Новая категория',
                      ),
                    ),
                    TextField(
                      controller: keyController,
                      decoration: const InputDecoration(
                        labelText: 'key (optional)',
                      ),
                    ),
                    TextField(
                      controller: iconController,
                      decoration: const InputDecoration(labelText: 'icon_key'),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          final title = titleController.text.trim();
                          final icon = iconController.text.trim();
                          if (title.isEmpty || icon.isEmpty) return;
                          setDialogState(() {
                            working = [
                              ...working,
                              ReferenceCategoryItem(
                                id: '',
                                key: keyController.text.trim().isEmpty
                                    ? null
                                    : keyController.text.trim(),
                                title: title,
                                iconKey: icon,
                                sortOrder: working.length,
                                rowVersion: 0,
                                status: ReferenceCategoryStatus.draft,
                              ),
                            ];
                            titleController.clear();
                            keyController.clear();
                            iconController.text = 'help';
                          });
                        },
                        child: const Text('Добавить в список'),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    titleController.dispose();
    iconController.dispose();
    keyController.dispose();
    if (saved != true || !mounted) return;

    await _run(() async {
      final persisted = <ReferenceCategoryItem>[];
      for (final category in working) {
        persisted.add(await _repository.upsertCategory(category));
      }
      if (persisted.length > 1) {
        await _repository.reorderCategories(
          [for (final c in persisted) c.id],
          [for (final c in persisted) c.rowVersion],
        );
      }
      await _reload();
      if (!mounted) return;
      setState(() => _banner = 'Категории обновлены');
    });
  }

  void _bindArticle(ReferenceArticleItem item) {
    _titleController.text = item.title;
    _iconKeyController.text = item.payload.iconKey;
    _shortTextController.text = item.payload.shortText;
    _blocks = List<ReferenceBlock>.from(item.payload.blocks);
    _sortOrderController.text = '${item.sortOrder}';
    _selectedCategoryId = item.categoryId;
    _audienceMode = item.audienceMode;
    _groupIds = item.audienceGroupIds;
    _userIds = item.audienceUserIds;
    setState(() {});
  }

  ReferenceArticlePayload? _draftPayload() {
    final wireBlocks = <Map<String, dynamic>>[];
    for (final block in _blocks) {
      wireBlocks.add(block.toWireJson());
    }
    return ReferenceArticlePayload.tryParseV2({
      'icon_key': _iconKeyController.text.trim(),
      'short_text': _shortTextController.text.trim(),
      'blocks': wireBlocks,
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createArticle() async {
    final payload = _draftPayload();
    final categoryId = _selectedCategoryId;
    final title = _titleController.text.trim();
    if (payload == null || categoryId == null || title.isEmpty) {
      setState(
        () => _banner =
            'Нельзя создать: заполните заголовок, поля и блоки '
            '(fail-closed, запись не создана).',
      );
      return;
    }
    await _run(() async {
      final created = await _repository.createArticleDraft(
        title: title,
        payload: payload,
        categoryId: categoryId,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedArticleId = created.id;
        _banner = 'Черновик статьи создан (schema 2, placement reference).';
      });
      final selected = _selectedArticle;
      if (selected != null) _bindArticle(selected);
    });
  }

  Future<void> _saveArticle() async {
    final selected = _selectedArticle;
    final payload = _draftPayload();
    final categoryId = _selectedCategoryId;
    if (selected == null || payload == null || categoryId == null) {
      setState(() => _banner = 'Проверьте поля статьи (fail-closed parse).');
      return;
    }
    await _run(() async {
      var next = selected.copyWith(
        title: _titleController.text.trim(),
        payload: payload,
        categoryId: categoryId,
      );
      next = await _repository.updateArticleDraft(next);
      next = await _repository.setArticleSortOrder(
        id: next.id,
        sortOrder: int.tryParse(_sortOrderController.text.trim()) ?? 0,
        expectedRowVersion: next.rowVersion,
      );
      next = await _repository.setAudience(
        id: next.id,
        audienceMode: _audienceMode,
        groupIds: _groupIds,
        userIds: _userIds,
        expectedRowVersion: next.rowVersion,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedArticleId = next.id;
        _banner = 'Сохранено.';
      });
      final rebound = _selectedArticle;
      if (rebound != null) _bindArticle(rebound);
    });
  }

  Future<void> _previewAudience() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      final preview = await _repository.previewAudience(selected.id);
      if (!mounted) return;
      setState(() {
        _banner = 'Preview аудитории: ${preview.recipientCount} получателей.';
      });
    });
  }

  Future<void> _publish() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      await _repository.publish(selected.id, selected.rowVersion);
      await _reload();
      setState(() => _banner = 'Опубликовано.');
    });
  }

  Future<void> _archive() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      await _repository.archive(selected.id, selected.rowVersion);
      await _reload();
      setState(() => _banner = 'В архиве.');
    });
  }

  Future<void> _resolveCorrection(
    ReferenceCorrectionItem item,
    String action,
  ) async {
    String reason = '';
    if (action == 'reject') {
      final confirmed = await _showRejectReasonDialog();
      if (confirmed == null) return;
      reason = confirmed;
    }
    await _run(() async {
      await _repository.resolveCorrection(
        id: item.id,
        action: action,
        reason: reason,
      );
      await _reload();
      setState(() => _banner = 'Обращение обработано.');
    });
  }

  Future<String?> _showRejectReasonDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Причина отклонения'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Причина (обязательно)',
              hintText: 'Опишите, почему обращение отклонено',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                Navigator.of(context).pop(text);
              },
              child: const Text('Отклонить'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  ManagedReferenceArticle? _previewArticle() {
    final selected = _selectedArticle;
    final payload = _draftPayload();
    final categoryId = _selectedCategoryId;
    if (selected == null || payload == null || categoryId == null) return null;
    final category = _categories.where((c) => c.id == categoryId).firstOrNull;
    return ManagedReferenceArticle(
      id: selected.id,
      title: _titleController.text.trim().isEmpty
          ? selected.title
          : _titleController.text.trim(),
      schemaVersion: 2,
      origin: selected.origin,
      sortOrder: int.tryParse(_sortOrderController.text.trim()) ?? 0,
      categoryId: categoryId,
      categoryTitle: category?.title ?? selected.categoryTitle ?? '',
      payload: payload,
      showDemoBadge: selected.origin == ContentOrigin.demo,
    );
  }

  void _addBlock(String type) {
    setState(() {
      _blocks = [
        ..._blocks,
        switch (type) {
          'text' => const ReferenceTextBlock(text: ''),
          'image' => const ReferenceImageBlock(assetId: ''),
          'file' => const ReferenceFileBlock(assetId: ''),
          'link' => const ReferenceLinkBlock(
            label: '',
            url: 'https://example.com',
          ),
          'cta' => const ReferenceCtaBlock(
            cta: ReferenceArticleCta(label: '', route: '/'),
          ),
          _ => const ReferenceTextBlock(text: ''),
        },
      ];
    });
  }

  void _updateBlock(int index, ReferenceBlock block) {
    setState(() {
      final next = List<ReferenceBlock>.from(_blocks);
      next[index] = block;
      _blocks = next;
    });
  }

  void _removeBlock(int index) {
    setState(() {
      final next = List<ReferenceBlock>.from(_blocks)..removeAt(index);
      _blocks = next.isEmpty ? [const ReferenceTextBlock(text: '')] : next;
    });
  }

  void _moveBlock(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _blocks.length) return;
    setState(() {
      final next = List<ReferenceBlock>.from(_blocks);
      final item = next.removeAt(index);
      next.insert(target, item);
      _blocks = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(child: Text(_loadError!));
    }

    final preview = _previewArticle();

    return SizedBox(
      height: 720,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (constraints.maxWidth >= 1000)
              Expanded(
                flex: 2,
                child: _ArticleListPanel(
                  articles: _articles,
                  selectedId: _selectedArticleId,
                  onSelect: (id) {
                    setState(() => _selectedArticleId = id);
                    final item = _selectedArticle;
                    if (item != null) _bindArticle(item);
                  },
                  onCreate: _canWrite ? _createArticle : null,
                ),
              ),
            Expanded(
              flex: 3,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Справочник',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Статьи `reference_article_v1` (schema 2) + категории '
                      'через dedicated RPC. Аудитория/publish — Stage 14 RPC.',
                    ),
                    if (_banner != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _banner!,
                        style: const TextStyle(color: Colors.green),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _selectedCategoryId,
                          decoration: const InputDecoration(
                            labelText: 'Категория',
                          ),
                          items: [
                            for (final category in _categories)
                              DropdownMenuItem(
                                value: category.id,
                                child: Text(
                                  category.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _canWrite
                              ? (value) =>
                                    setState(() => _selectedCategoryId = value)
                              : null,
                        ),
                        if (_canWrite) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _manageCategories,
                              icon: const Icon(Icons.category_outlined),
                              label: const Text('Категории'),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _titleController,
                      enabled: _canWrite,
                      decoration: const InputDecoration(labelText: 'Заголовок'),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _iconKeyController,
                      enabled: _canWrite,
                      decoration: const InputDecoration(labelText: 'icon_key'),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _shortTextController,
                      enabled: _canWrite,
                      decoration: const InputDecoration(
                        labelText: 'short_text',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _sortOrderController,
                      enabled: _canWrite,
                      decoration: const InputDecoration(
                        labelText: 'sort_order',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ReferenceBlocksEditor(
                      blocks: _blocks,
                      enabled: _canWrite,
                      contentItemId: _selectedArticleId,
                      onAdd: _addBlock,
                      onUpdate: _updateBlock,
                      onRemove: _removeBlock,
                      onMove: _moveBlock,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _audienceMode,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Аудитория'),
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('Все')),
                        DropdownMenuItem(
                          value: 'groups',
                          child: Text('Группы'),
                        ),
                        DropdownMenuItem(
                          value: 'users',
                          child: Text('Пользователи'),
                        ),
                        DropdownMenuItem(
                          value: 'groups_and_users',
                          child: Text(
                            'Группы и пользователи',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: _canWrite
                          ? (value) {
                              if (value == null) return;
                              setState(() => _audienceMode = value);
                            }
                          : null,
                    ),
                    ContentAudienceSelectors(
                      studentsRepository: _studentsRepository,
                      audienceMode: _audienceMode,
                      selectedGroupIds: _groupIds,
                      selectedUserIds: _userIds,
                      enabled: _canWrite,
                      onChanged: ({required groupIds, required userIds}) {
                        setState(() {
                          _groupIds = groupIds;
                          _userIds = userIds;
                        });
                      },
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_canWrite)
                          FilledButton(
                            onPressed: _busy ? null : _saveArticle,
                            child: const Text('Сохранить'),
                          ),
                        if (_canWrite)
                          OutlinedButton(
                            onPressed: _busy ? null : _previewAudience,
                            child: const Text('Preview аудитории'),
                          ),
                        if (_canPublish)
                          FilledButton.tonal(
                            onPressed: _busy ? null : _publish,
                            child: const Text('Опубликовать'),
                          ),
                        if (_canPublish)
                          OutlinedButton(
                            onPressed: _busy ? null : _archive,
                            child: const Text('В архив'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Обращения об ошибках (${_corrections.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_corrections.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Открытых обращений нет.'),
                      )
                    else
                      for (final correction in _corrections)
                        ListTile(
                          title: Text(correction.contentTitle),
                          subtitle: Text(correction.note),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _resolveCorrection(
                                        correction,
                                        'resolve',
                                      ),
                                child: const Text('Закрыть'),
                              ),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _resolveCorrection(
                                        correction,
                                        'reject',
                                      ),
                                child: const Text('Отклонить'),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
            if (preview != null)
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Preview · список справочника',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Expanded(
                        child: AdminStudentPhoneFrame(
                          showBottomNavigation: true,
                          navigationIndex: 1,
                          child: Scaffold(
                            backgroundColor: const Color(0xFFFAF8FC),
                            appBar: AppBar(
                              title: const Text('Справочник'),
                              backgroundColor: const Color(0xFFFAF8FC),
                              surfaceTintColor: Colors.transparent,
                            ),
                            body: ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                Text(
                                  preview.categoryTitle,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                StudentReferenceArticleCard(article: preview),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceBlocksEditor extends StatelessWidget {
  const _ReferenceBlocksEditor({
    required this.blocks,
    required this.enabled,
    required this.contentItemId,
    required this.onAdd,
    required this.onUpdate,
    required this.onRemove,
    required this.onMove,
  });

  final List<ReferenceBlock> blocks;
  final bool enabled;
  final String? contentItemId;
  final ValueChanged<String> onAdd;
  final void Function(int index, ReferenceBlock block) onUpdate;
  final ValueChanged<int> onRemove;
  final void Function(int index, int delta) onMove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              'Блоки контента',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (enabled)
              PopupMenuButton<String>(
                onSelected: onAdd,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'text', child: Text('Текст')),
                  PopupMenuItem(value: 'image', child: Text('Изображение')),
                  PopupMenuItem(value: 'file', child: Text('Файл')),
                  PopupMenuItem(value: 'link', child: Text('Ссылка')),
                  PopupMenuItem(value: 'cta', child: Text('CTA')),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 18),
                      SizedBox(width: 4),
                      Text('Добавить блок'),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < blocks.length; i++)
          _ReferenceBlockTile(
            key: ValueKey('block-$i-${blocks[i].type}'),
            index: i,
            block: blocks[i],
            enabled: enabled,
            contentItemId: contentItemId,
            canMoveUp: i > 0,
            canMoveDown: i < blocks.length - 1,
            onUpdate: (block) => onUpdate(i, block),
            onRemove: () => onRemove(i),
            onMoveUp: () => onMove(i, -1),
            onMoveDown: () => onMove(i, 1),
          ),
      ],
    );
  }
}

class _ReferenceBlockTile extends StatefulWidget {
  const _ReferenceBlockTile({
    super.key,
    required this.index,
    required this.block,
    required this.enabled,
    required this.contentItemId,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onUpdate,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final int index;
  final ReferenceBlock block;
  final bool enabled;
  final String? contentItemId;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<ReferenceBlock> onUpdate;
  final VoidCallback onRemove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  State<_ReferenceBlockTile> createState() => _ReferenceBlockTileState();
}

class _ReferenceBlockTileState extends State<_ReferenceBlockTile> {
  late TextEditingController _primary;
  late TextEditingController _secondary;
  late TextEditingController _tertiary;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _syncControllers(widget.block);
  }

  Future<void> _uploadMedia({
    required bool image,
    required ValueChanged<String> onAsset,
  }) async {
    final itemId = widget.contentItemId;
    if (itemId == null || itemId.isEmpty || _uploading) return;
    final picked = await FilePicker.pickFiles(
      type: image ? FileType.image : FileType.custom,
      allowedExtensions: image
          ? null
          : const ['pdf', 'png', 'jpg', 'jpeg', 'webp'],
      withData: true,
    );
    final file = picked?.files.single;
    final bytes = file?.bytes;
    if (bytes == null || bytes.isEmpty) return;
    final name = (file?.name ?? '').toLowerCase();
    final contentType = name.endsWith('.png')
        ? 'image/png'
        : name.endsWith('.webp')
        ? 'image/webp'
        : name.endsWith('.pdf')
        ? 'application/pdf'
        : 'image/jpeg';
    setState(() => _uploading = true);
    try {
      final assetId = await ContentMediaStore().uploadBytes(
        contentItemId: itemId,
        bytes: bytes,
        contentType: contentType,
        title: file?.name ?? '',
      );
      _primary.text = assetId;
      onAsset(assetId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить файл: $error')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void didUpdateWidget(covariant _ReferenceBlockTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.type != widget.block.type ||
        oldWidget.block.toWireJson().toString() !=
            widget.block.toWireJson().toString()) {
      _syncControllers(widget.block);
    }
  }

  void _syncControllers(ReferenceBlock block) {
    switch (block) {
      case ReferenceTextBlock(:final text):
        _primary = TextEditingController(text: text);
        _secondary = TextEditingController();
        _tertiary = TextEditingController();
      case ReferenceImageBlock(:final assetId, :final caption):
        _primary = TextEditingController(text: assetId);
        _secondary = TextEditingController(text: caption ?? '');
        _tertiary = TextEditingController();
      case ReferenceFileBlock(:final assetId, :final title):
        _primary = TextEditingController(text: assetId);
        _secondary = TextEditingController(text: title ?? '');
        _tertiary = TextEditingController();
      case ReferenceLinkBlock(:final label, :final url):
        _primary = TextEditingController(text: label);
        _secondary = TextEditingController(text: url);
        _tertiary = TextEditingController();
      case ReferenceCtaBlock(:final cta):
        _primary = TextEditingController(text: cta.label);
        _secondary = TextEditingController(text: cta.route ?? '');
        _tertiary = TextEditingController(text: cta.url ?? '');
    }
  }

  @override
  void dispose() {
    _primary.dispose();
    _secondary.dispose();
    _tertiary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Блок ${widget.index + 1}: ${block.type}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const Spacer(),
                if (widget.enabled) ...[
                  IconButton(
                    tooltip: 'Выше',
                    onPressed: widget.canMoveUp ? widget.onMoveUp : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    tooltip: 'Ниже',
                    onPressed: widget.canMoveDown ? widget.onMoveDown : null,
                    icon: const Icon(Icons.arrow_downward),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: widget.onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            switch (block) {
              ReferenceTextBlock() => TextField(
                enabled: widget.enabled,
                controller: _primary,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'text',
                  alignLabelWithHint: true,
                ),
                onChanged: (value) =>
                    widget.onUpdate(ReferenceTextBlock(text: value)),
              ),
              ReferenceImageBlock() => Column(
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'asset_id'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceImageBlock(
                        assetId: value,
                        caption: _secondary.text.trim().isEmpty
                            ? null
                            : _secondary.text.trim(),
                      ),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(
                      labelText: 'caption (опц.)',
                    ),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceImageBlock(
                        assetId: _primary.text,
                        caption: value.trim().isEmpty ? null : value.trim(),
                      ),
                    ),
                  ),
                  if (widget.enabled && widget.contentItemId != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _uploadMedia(
                          image: true,
                          onAsset: (id) => widget.onUpdate(
                            ReferenceImageBlock(
                              assetId: id,
                              caption: _secondary.text.trim().isEmpty
                                  ? null
                                  : _secondary.text.trim(),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Загрузить изображение'),
                      ),
                    ),
                ],
              ),
              ReferenceFileBlock() => Column(
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'asset_id'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceFileBlock(
                        assetId: value,
                        title: _secondary.text.trim().isEmpty
                            ? null
                            : _secondary.text.trim(),
                      ),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(
                      labelText: 'title (опц.)',
                    ),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceFileBlock(
                        assetId: _primary.text,
                        title: value.trim().isEmpty ? null : value.trim(),
                      ),
                    ),
                  ),
                  if (widget.enabled && widget.contentItemId != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _uploadMedia(
                          image: false,
                          onAsset: (id) => widget.onUpdate(
                            ReferenceFileBlock(
                              assetId: id,
                              title: _secondary.text.trim().isEmpty
                                  ? null
                                  : _secondary.text.trim(),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Загрузить файл'),
                      ),
                    ),
                ],
              ),
              ReferenceLinkBlock() => Column(
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'label'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceLinkBlock(label: value, url: _secondary.text),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(labelText: 'url'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceLinkBlock(label: _primary.text, url: value),
                    ),
                  ),
                ],
              ),
              ReferenceCtaBlock() => Column(
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'label'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceCtaBlock(
                        cta: ReferenceArticleCta(
                          label: value,
                          route: _secondary.text.trim().isEmpty
                              ? null
                              : _secondary.text.trim(),
                          url: _tertiary.text.trim().isEmpty
                              ? null
                              : _tertiary.text.trim(),
                        ),
                      ),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(
                      labelText: 'route (опц.)',
                    ),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceCtaBlock(
                        cta: ReferenceArticleCta(
                          label: _primary.text,
                          route: value.trim().isEmpty ? null : value.trim(),
                          url: _tertiary.text.trim().isEmpty
                              ? null
                              : _tertiary.text.trim(),
                        ),
                      ),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _tertiary,
                    decoration: const InputDecoration(labelText: 'url (опц.)'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceCtaBlock(
                        cta: ReferenceArticleCta(
                          label: _primary.text,
                          route: _secondary.text.trim().isEmpty
                              ? null
                              : _secondary.text.trim(),
                          url: value.trim().isEmpty ? null : value.trim(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}

class _ArticleListPanel extends StatelessWidget {
  const _ArticleListPanel({
    required this.articles,
    required this.selectedId,
    required this.onSelect,
    this.onCreate,
  });

  final List<ReferenceArticleItem> articles;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: const Text('Статьи справочника'),
            trailing: onCreate == null
                ? null
                : TextButton(
                    onPressed: onCreate,
                    child: const Text('Новая статья'),
                  ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: articles.length,
              itemBuilder: (context, index) {
                final item = articles[index];
                return ListTile(
                  selected: item.id == selectedId,
                  title: Text(item.title),
                  subtitle: Text(referenceArticleStatusWire(item.status)),
                  onTap: () => onSelect(item.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
