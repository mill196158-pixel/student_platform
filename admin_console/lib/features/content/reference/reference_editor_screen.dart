import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../academic/students/students_repository.dart';
import '../profile_feed/content_audience_selectors.dart';
import '../shared/admin_content_backend.dart';
import '../shared/content_action_model.dart';
import '../shared/content_action_picker.dart';
import '../shared/content_icon_picker.dart';
import '../shared/content_technical_panel.dart';
import '../shared/phone_preview_frame.dart';
import '../shared/visual_editor_list_panel.dart';
import '../shared/visual_editor_shell.dart';
import '../shared/visual_editor_states.dart';
import 'content_media_store.dart';
import 'reference_item.dart';
import 'reference_preview.dart';
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
  String? _filterCategoryId;
  VisualEditorListTab _listTab = VisualEditorListTab.published;
  bool _showDemoOnly = false;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  bool _editingWorkingDraft = false;
  String _audienceMode = 'all';
  List<String> _groupIds = const [];
  List<String> _userIds = const [];
  ReferenceAudiencePreview? _audiencePreview;
  String? _banner;
  String? _successBanner;
  String? _loadError;
  _EditorSnapshot? _boundSnapshot;
  late final StudentsRepository _studentsRepository = _defaultStudentsRepo();

  ReferenceAdminListPartitions get _partitions =>
      partitionAdminReference(_articles);

  ReferenceArticleItem? get _selectedArticle {
    for (final item in _articles) {
      if (item.id == _selectedArticleId) return item;
    }
    return null;
  }

  List<ReferenceArticleItem> get _tabItems {
    final parts = _partitions;
    final base = switch (_listTab) {
      VisualEditorListTab.published => parts.published,
      VisualEditorListTab.drafts => parts.drafts,
      VisualEditorListTab.archived => parts.archived,
    };
    return base
        .where((item) => !_showDemoOnly || item.origin == ContentOrigin.demo)
        .where(
          (item) =>
              _filterCategoryId == null || item.categoryId == _filterCategoryId,
        )
        .toList();
  }

  VisualEditorTabCounts get _tabCounts => VisualEditorTabCounts(
    published: _partitions.published.length,
    drafts: _partitions.drafts.length,
    archived: _partitions.archived.length,
  );

  bool get _canWrite =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canWriteContent;

  bool get _canPublish =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canPublishContent;

  bool get _canReadModeration =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.can('moderation.read');

  ReferenceRepository _defaultRepo() {
    return AdminContentBackend.resolveRepository<ReferenceRepository>(
      isDemoMode: AdminBackendConfig.isDemoMode,
      client: _tryClient(),
      localFactory: LocalReferenceRepository.new,
      supabaseFactory: (client) => SupabaseReferenceRepository(client: client),
    );
  }

  StudentsRepository _defaultStudentsRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalStudentsRepository();
    final client = _tryClient();
    if (client != null) return SupabaseStudentsRepository(client: client);
    if (widget.repository != null) return LocalStudentsRepository();
    throw StateError(AdminContentBackend.realUnavailableMessage);
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

  Future<void> _reload({String? selectId}) async {
    final hadData = _categories.isNotEmpty || _articles.isNotEmpty;
    setState(() {
      if (!hadData) {
        _loading = true;
        _loadError = null;
      }
    });
    try {
      final categories = await _repository.listCategories();
      final articles = await _repository.listArticles();
      final corrections = _canReadModeration
          ? await _repository.listCorrections()
          : _corrections;
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _articles = articles;
        _corrections = corrections;
        if (selectId != null) {
          _selectedArticleId = selectId;
        }
        _ensureSelectionForTab();
        _loading = false;
        _loadError = null;
      });
      _bindSelected();
    } catch (error) {
      if (!mounted) return;
      final message = error is ReferenceRepositoryException
          ? error.message
          : error.toString();
      setState(() {
        _loading = false;
        if (_categories.isEmpty && _articles.isEmpty) {
          _loadError = message;
        } else {
          _banner = message;
        }
      });
    }
  }

  void _ensureSelectionForTab() {
    final tabItems = _tabItems;
    if (tabItems.isEmpty) {
      _selectedArticleId = null;
      return;
    }
    if (_selectedArticleId != null &&
        tabItems.any((item) => item.id == _selectedArticleId)) {
      return;
    }
    _selectedArticleId = tabItems.first.id;
  }

  void _select(String id) {
    if (id == _selectedArticleId) return;
    setState(() {
      _selectedArticleId = id;
      _editingWorkingDraft = false;
    });
    _bindSelected();
  }

  Future<void> _beginEdit() async {
    final selected = _selectedArticle;
    if (selected == null || !_canWrite) return;
    await _run(() async {
      final item = await _repository.beginEdit(selected.id);
      if (!mounted) return;
      setState(() {
        final idx = _articles.indexWhere((e) => e.id == item.id);
        if (idx >= 0) _articles = [..._articles]..[idx] = item;
        _editingWorkingDraft = true;
      });
      _bindSelected();
    });
  }

  Future<void> _discardWorkingDraft() async {
    final selected = _selectedArticle;
    if (selected == null || !_canWrite) return;
    await _run(() async {
      final item = await _repository.discardWorkingDraft(selected.id);
      if (!mounted) return;
      setState(() {
        _editingWorkingDraft = false;
        final idx = _articles.indexWhere((e) => e.id == item.id);
        if (idx >= 0) _articles = [..._articles]..[idx] = item;
      });
      _bindSelected();
      setState(() => _successBanner = 'Изменения отменены.');
    });
  }

  Future<void> _manageCategories() async {
    final titleController = TextEditingController();
    var newCategoryIconKey = 'help';
    final keyController = TextEditingController();
    var working = List<ReferenceCategoryItem>.from(_categories);

    Future<void> editCategory(
      void Function(void Function()) setDialogState,
      int index,
    ) async {
      final current = working[index];
      final editTitle = TextEditingController(text: current.title);
      var editIconKey = current.iconKey;
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
                      const SizedBox(height: 8),
                      ContentIconPickerField(
                        selectedKey: editIconKey,
                        onChanged: (value) {
                          if (value != null) {
                            setEditState(() => editIconKey = value);
                          }
                        },
                      ),
                      DropdownButtonFormField<ReferenceCategoryStatus>(
                        value: status,
                        decoration: const InputDecoration(labelText: 'Статус'),
                        items: [
                          for (final s in ReferenceCategoryStatus.values)
                            DropdownMenuItem(
                              value: s,
                              child: Text(s.russianLabel),
                            ),
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
      editTitle.dispose();
      if (ok != true || nextTitle.isEmpty || editIconKey.isEmpty) return;
      setDialogState(() {
        working = [...working];
        working[index] = current.copyWith(
          title: nextTitle,
          iconKey: editIconKey,
          status: status,
        );
      });
    }

    Future<void> deleteCategory(
      void Function(void Function()) setDialogState,
      int index,
    ) async {
      final current = working[index];
      if (current.id.isEmpty) {
        setDialogState(() {
          working = [...working]..removeAt(index);
        });
        return;
      }
      final others = [
        for (var j = 0; j < working.length; j++)
          if (j != index && working[j].id.isNotEmpty) working[j],
      ];
      String mode = 'archive_articles';
      String? reassignToId;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDeleteState) {
              return AlertDialog(
                title: Text('Удалить «${current.title}»?'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((current.articleCount ?? 0) > 0)
                        Text(
                          'В категории ${current.articleCount} стат.'
                          '${(current.articleCount ?? 0) == 1 ? 'ья' : 'ей'}.',
                        ),
                      const SizedBox(height: 12),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          'Перенести статьи в другую категорию',
                        ),
                        value: 'reassign',
                        groupValue: mode,
                        onChanged: others.isEmpty
                            ? null
                            : (value) {
                                if (value == null) return;
                                setDeleteState(() => mode = value);
                              },
                      ),
                      if (mode == 'reassign' && others.isNotEmpty)
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: reassignToId ?? others.first.id,
                          decoration: const InputDecoration(
                            labelText: 'Целевая категория',
                          ),
                          items: [
                            for (final cat in others)
                              DropdownMenuItem(
                                value: cat.id,
                                child: Text(cat.title),
                              ),
                          ],
                          onChanged: (value) =>
                              setDeleteState(() => reassignToId = value),
                        ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          'Архивировать статьи и удалить категорию',
                        ),
                        value: 'archive_articles',
                        groupValue: mode,
                        onChanged: (value) {
                          if (value == null) return;
                          setDeleteState(() => mode = value);
                        },
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Удалить'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (confirmed != true) return;
      if (mode == 'reassign' &&
          (reassignToId == null || reassignToId!.isEmpty)) {
        if (others.isEmpty) return;
        reassignToId = others.first.id;
      }
      try {
        await _repository.safeDeleteCategory(
          id: current.id,
          expectedRowVersion: current.rowVersion,
          mode: mode,
          reassignToId: reassignToId,
        );
        setDialogState(() {
          working = [...working]..removeAt(index);
        });
      } on ReferenceRepositoryException catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
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
                          '${working[i].iconKey} · ${working[i].status.russianLabel}'
                          '${working[i].articleCount != null ? ' · ${working[i].articleCount} стат.' : ''}',
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
                                  PopupMenuItem(
                                    value: s,
                                    child: Text(s.russianLabel),
                                  ),
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
                            IconButton(
                              tooltip: 'Удалить',
                              onPressed: () =>
                                  deleteCategory(setDialogState, i),
                              icon: const Icon(Icons.delete_outline),
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
                    ContentIconPickerField(
                      selectedKey: newCategoryIconKey,
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => newCategoryIconKey = value);
                        }
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          final title = titleController.text.trim();
                          if (title.isEmpty || newCategoryIconKey.isEmpty) {
                            return;
                          }
                          setDialogState(() {
                            working = [
                              ...working,
                              ReferenceCategoryItem(
                                id: '',
                                key: keyController.text.trim().isEmpty
                                    ? null
                                    : keyController.text.trim(),
                                title: title,
                                iconKey: newCategoryIconKey,
                                sortOrder: working.length,
                                rowVersion: 0,
                                status: ReferenceCategoryStatus.draft,
                              ),
                            ];
                            titleController.clear();
                            keyController.clear();
                            newCategoryIconKey = 'help';
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
      setState(() => _successBanner = 'Категории обновлены');
    });
  }

  void _bindSelected() {
    final selected = _selectedArticle;
    if (selected == null) {
      _boundSnapshot = null;
      setState(() {
        _dirty = false;
        _banner = null;
        _successBanner = null;
        _audiencePreview = null;
      });
      return;
    }
    _titleController.text = selected.title;
    _iconKeyController.text = selected.payload.iconKey;
    _shortTextController.text = selected.payload.shortText;
    _blocks = List<ReferenceBlock>.from(selected.payload.blocks);
    _sortOrderController.text = '${selected.sortOrder}';
    _selectedCategoryId = selected.categoryId;
    _audienceMode = selected.audienceMode;
    _groupIds = [...selected.audienceGroupIds];
    _userIds = [...selected.audienceUserIds];
    _audiencePreview = null;
    _boundSnapshot = _captureSnapshot();
    setState(() {
      _dirty = false;
      _banner = null;
      _successBanner = null;
    });
  }

  _EditorSnapshot _captureSnapshot() {
    return _EditorSnapshot(
      title: _titleController.text,
      iconKey: _iconKeyController.text,
      shortText: _shortTextController.text,
      sortOrder: _sortOrderController.text,
      categoryId: _selectedCategoryId,
      audienceMode: _audienceMode,
      groupIds: [..._groupIds],
      userIds: [..._userIds],
      blocksWire: [for (final block in _blocks) block.toWireJson().toString()],
    );
  }

  void _markDirty() {
    final nextDirty =
        _boundSnapshot != null && _captureSnapshot() != _boundSnapshot;
    setState(() => _dirty = nextDirty);
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
      _successBanner = null;
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

  Future<ReferenceArticleItem?> _saveSelected() async {
    final selected = _selectedArticle;
    final payload = _draftPayload();
    final categoryId = _selectedCategoryId;
    if (selected == null || payload == null || categoryId == null) {
      setState(() => _banner = 'Проверьте поля статьи (fail-closed parse).');
      return null;
    }
    final blockAssetIds = <String>[
      for (final block in payload.blocks)
        if (block is ReferenceImageBlock) block.assetId,
      for (final block in payload.blocks)
        if (block is ReferenceFileBlock) block.assetId,
    ];
    var next = selected.copyWith(
      title: _titleController.text.trim(),
      payload: payload,
      schemaVersion: selected.effectiveSchemaVersion,
      categoryId: categoryId,
      sortOrder:
          int.tryParse(_sortOrderController.text.trim()) ?? selected.sortOrder,
      audienceMode: _audienceMode,
      audienceGroupIds: _groupIds,
      audienceUserIds: _userIds,
      draftAssetIds: {...selected.draftAssetIds, ...blockAssetIds}.toList(),
    );
    if (_editingWorkingDraft) {
      final draftVersion = selected.workingDraftRowVersion;
      if (draftVersion == null) {
        setState(() => _banner = 'Черновик изменений не найден.');
        return null;
      }
      next = await _repository.saveWorkingDraft(
        next,
        expectedDraftRowVersion: draftVersion,
      );
      if (!mounted) return next;
      setState(() {
        final idx = _articles.indexWhere((e) => e.id == next.id);
        if (idx >= 0) _articles = [..._articles]..[idx] = next;
        _selectedArticleId = next.id;
        _dirty = false;
        _boundSnapshot = _captureSnapshot();
      });
      return next;
    }
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
    if (!mounted) return next;
    setState(() {
      final idx = _articles.indexWhere((e) => e.id == next.id);
      if (idx >= 0) _articles = [..._articles]..[idx] = next;
      _selectedArticleId = next.id;
      _dirty = false;
      _boundSnapshot = _captureSnapshot();
    });
    return next;
  }

  Future<void> _saveDraft() async {
    if (!_canWrite) {
      setState(() => _banner = 'Недостаточно прав для сохранения.');
      return;
    }
    await _run(() async {
      final saved = await _saveSelected();
      if (saved != null) {
        setState(() => _successBanner = 'Черновик сохранён.');
      }
    });
  }

  Future<void> _createArticle() async {
    final payload = _draftPayload();
    final categoryId =
        _selectedCategoryId ??
        _filterCategoryId ??
        (_categories.isEmpty ? null : _categories.first.id);
    final title = _titleController.text.trim().isEmpty
        ? 'Новая статья справочника'
        : _titleController.text.trim();
    if (payload == null || categoryId == null) {
      setState(
        () => _banner =
            'Нельзя создать: заполните поля и блоки '
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
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: created.id);
      setState(() => _successBanner = 'Черновик статьи создан.');
    });
  }

  Future<void> _previewAudience() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      final preview = await _repository.previewAudience(selected.id);
      if (!mounted) return;
      setState(() => _audiencePreview = preview);
    });
  }

  Future<void> _publish() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      var current = selected;
      if (_dirty) {
        final saved = await _saveSelected();
        if (saved == null) return;
        current = saved;
      }
      if (_editingWorkingDraft) {
        final draftVersion = current.workingDraftRowVersion;
        if (draftVersion == null) {
          setState(() => _banner = 'Черновик изменений не найден.');
          return;
        }
        await _repository.publishWorkingDraft(
          current.id,
          expectedDraftRowVersion: draftVersion,
        );
        if (!mounted) return;
        setState(() {
          _editingWorkingDraft = false;
          _listTab = VisualEditorListTab.published;
        });
        await _reload(selectId: current.id);
        setState(() => _successBanner = 'Изменения опубликованы.');
        return;
      }
      await _repository.publish(current.id, current.rowVersion);
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.published);
      await _reload(selectId: current.id);
      setState(() => _successBanner = 'Опубликовано.');
    });
  }

  Future<void> _archive() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      await _repository.archive(selected.id, selected.rowVersion);
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.archived);
      await _reload(selectId: selected.id);
      setState(() => _successBanner = 'Перемещено в архив.');
    });
  }

  Future<void> _unpublish() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      await _repository.unpublish(selected.id, selected.rowVersion);
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: selected.id);
      setState(() => _successBanner = 'Снято с публикации.');
    });
  }

  Future<void> _unarchive() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    await _run(() async {
      await _repository.unarchive(selected.id, selected.rowVersion);
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: selected.id);
      setState(() => _successBanner = 'Восстановлено как черновик.');
    });
  }

  Future<void> _promoteDemo() async {
    final selected = _selectedArticle;
    if (selected == null || selected.origin != ContentOrigin.demo) return;
    await _run(() async {
      await _repository.promoteDemo(selected.id, selected.rowVersion);
      await _reload(selectId: selected.id);
      if (mounted) {
        setState(
          () => _successBanner = 'Демо-статья переведена в управляемую.',
        );
      }
    });
  }

  Future<void> _showVersions() async {
    final selected = _selectedArticle;
    if (selected == null) return;
    List<ReferenceVersionInfo>? versions;
    await _run(() async {
      versions = await _repository.listVersions(selected.id);
    });
    if (versions == null || !mounted) return;
    if (versions!.isEmpty) {
      setState(() => _successBanner = 'История версий пуста.');
      return;
    }
    final restore = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _VersionHistoryDialog(versions: versions!),
    );
    if (restore == null) return;
    await _run(() async {
      final restored = await _repository.restoreVersion(
        selected.id,
        restore,
        selected.rowVersion,
      );
      await _reload(selectId: restored.id);
      setState(() => _successBanner = 'Версия $restore восстановлена.');
    });
  }

  Future<void> _handlePopDirtyConfirm() async {
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

  Future<void> _safeDelete() async {
    final selected = _selectedArticle;
    if (selected == null ||
        selected.status != ReferenceArticleStatus.archived) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить статью навсегда?'),
        content: const Text(
          'Будет удалена только архивная статья. Демо-ключ останется помеченным, '
          'поэтому bootstrap не создаст её повторно.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _repository.safeDelete(selected.id, selected.rowVersion);
      await _reload();
      if (mounted) setState(() => _successBanner = 'Статья удалена.');
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
      setState(() => _successBanner = 'Обращение обработано.');
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
      schemaVersion: selected.effectiveSchemaVersion,
      origin: selected.origin,
      sortOrder: int.tryParse(_sortOrderController.text.trim()) ?? 0,
      categoryId: categoryId,
      categoryTitle: category?.title ?? selected.categoryTitle ?? '',
      payload: payload,
      showDemoBadge: selected.origin == ContentOrigin.demo,
    );
  }

  List<ManagedReferenceArticle> _previewArticles() {
    final selected = _selectedArticle;
    var published = _partitions.publishedPreviewItems;
    if (_filterCategoryId != null) {
      published = published
          .where((item) => item.categoryId == _filterCategoryId)
          .toList();
    }
    final cards = published
        .map((item) => item.toManagedArticle())
        .toList(growable: true);

    if (selected == null) return cards;

    final selectedPublished =
        selected.status == ReferenceArticleStatus.published &&
        published.any((item) => item.id == selected.id);
    if (selectedPublished) return cards;

    final draft = _previewArticle();
    if (draft == null) return cards;
    cards.removeWhere((item) => item.id == draft.id);
    cards.insert(0, draft);
    return cards;
  }

  String? get _headerBanner => _banner;

  String? get _infoBanner {
    if (_banner != null) return null;
    return _successBanner;
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
          'heading' => const ReferenceHeadingBlock(text: ''),
          'info' => const ReferenceInfoBlock(text: ''),
          'warning' => const ReferenceWarningBlock(text: ''),
          'list' => const ReferenceListBlock(style: 'bullet', items: ['']),
          _ => const ReferenceTextBlock(text: ''),
        },
      ];
    });
    _markDirty();
  }

  void _duplicateBlock(int index) {
    setState(() {
      final block = _blocks[index];
      _blocks = [
        ..._blocks.sublist(0, index + 1),
        block,
        ..._blocks.sublist(index + 1),
      ];
    });
    _markDirty();
  }

  void _updateBlock(int index, ReferenceBlock block) {
    setState(() {
      final next = List<ReferenceBlock>.from(_blocks);
      next[index] = block;
      _blocks = next;
    });
    _markDirty();
  }

  void _removeBlock(int index) {
    setState(() {
      final next = List<ReferenceBlock>.from(_blocks)..removeAt(index);
      _blocks = next.isEmpty ? [const ReferenceTextBlock(text: '')] : next;
    });
    _markDirty();
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
    _markDirty();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: VisualEditorLoadingState(),
      );
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: VisualEditorErrorState(
          message: _loadError!,
          onRetry: () {
            setState(() => _loading = true);
            _reload();
          },
        ),
      );
    }

    final selected = _selectedArticle;
    final previewArticles = _previewArticles();
    final isArchived = selected?.status == ReferenceArticleStatus.archived;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: VisualEditorShell(
        title: 'Справочник · статьи',
        selectedTitle: selected?.title,
        statusChip: selected?.status.russianLabel,
        originDemoBadge: selected?.origin == ContentOrigin.demo,
        dirty: _dirty,
        busy: _busy,
        banner: _headerBanner,
        defaultInfoMessage:
            _infoBanner ??
            'Статьи `reference_article_v1` (schema 2). '
                'Публикация видна студентам сразу.',
        canWrite: _canWrite,
        canPublish: _canPublish && selected != null && !isArchived,
        canUnpublish: _canPublish,
        isPublished: selected?.status == ReferenceArticleStatus.published,
        isArchived: isArchived,
        listTab: _listTab,
        tabCounts: _tabCounts,
        onTabChanged: (tab) {
          setState(() {
            _listTab = tab;
            _editingWorkingDraft = false;
            _ensureSelectionForTab();
          });
          _bindSelected();
        },
        onCreate: _canWrite ? _createArticle : null,
        onSaveDraft:
            _canWrite && (selected?.isDraft == true || _editingWorkingDraft)
            ? _saveDraft
            : null,
        onPublish: _canPublish ? _publish : null,
        onUnpublish: _canPublish ? _unpublish : null,
        onVersions: _showVersions,
        onPopDirtyConfirm: _handlePopDirtyConfirm,
        editingWorkingDraft: _editingWorkingDraft,
        onDiscardWorkingDraft: _editingWorkingDraft && _canWrite
            ? _discardWorkingDraft
            : null,
        listBuilder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: const Text('Все'),
                  selected: _filterCategoryId == null,
                  onSelected: (_) {
                    setState(() {
                      _filterCategoryId = null;
                      _ensureSelectionForTab();
                    });
                    _bindSelected();
                  },
                ),
                for (final category in _categories)
                  FilterChip(
                    label: Text(category.title),
                    selected: _filterCategoryId == category.id,
                    onSelected: (_) {
                      setState(() {
                        _filterCategoryId = category.id;
                        _ensureSelectionForTab();
                      });
                      _bindSelected();
                    },
                  ),
              ],
            ),
            if (_canWrite) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _manageCategories,
                  icon: const Icon(Icons.category_outlined),
                  label: const Text('Управление категориями'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: VisualEditorListPanel(
                panelTitle: 'Статьи справочника',
                tab: _listTab,
                tabCounts: _tabCounts,
                items: [
                  for (final item in _tabItems)
                    VisualEditorListItem(
                      id: item.id,
                      title: item.title,
                      subtitle: item.payload.shortText,
                      isDemo: item.origin == ContentOrigin.demo,
                      statusLabel: item.status.russianLabel,
                    ),
                ],
                selectedId: _selectedArticleId,
                onTabChanged: (tab) {
                  setState(() {
                    _listTab = tab;
                    _editingWorkingDraft = false;
                    _ensureSelectionForTab();
                  });
                  _bindSelected();
                },
                onSelected: _select,
                onCreate: _canWrite ? _createArticle : null,
                showDemoOnly: _showDemoOnly,
                onDemoFilterChanged: (value) {
                  setState(() {
                    _showDemoOnly = value;
                    _ensureSelectionForTab();
                  });
                  _bindSelected();
                },
              ),
            ),
          ],
        ),
        previewBuilder: (_) => _ReferencePhonePreview(
          categories: [
            for (final c in _categories)
              ReferenceCategory(
                id: c.id,
                key: c.key ?? c.id,
                title: c.title,
                iconKey: c.iconKey,
                sortOrder: c.sortOrder,
              ),
          ],
          articles: previewArticles,
          selectedId: selected?.id,
          liveDraft: _previewArticle(),
          onArticleSelected: (article) => _select(article.id),
        ),
        propertiesBuilder: (_) => selected == null
            ? VisualEditorEmptyState(
                message: _tabItems.isEmpty
                    ? _listTab.emptyMessageRu
                    : 'Выберите статью',
                actionLabel: _canWrite && _tabItems.isEmpty ? 'Создать' : null,
                onAction: _canWrite && _tabItems.isEmpty
                    ? _createArticle
                    : null,
              )
            : _ReferencePropertiesPanel(
                selected: selected,
                categories: _categories,
                corrections: _corrections,
                canWrite: _canWrite,
                canPublish: _canPublish,
                editingWorkingDraft: _editingWorkingDraft,
                busy: _busy,
                titleController: _titleController,
                iconKeyController: _iconKeyController,
                shortTextController: _shortTextController,
                sortOrderController: _sortOrderController,
                selectedCategoryId: _selectedCategoryId,
                blocks: _blocks,
                audienceMode: _audienceMode,
                groupIds: _groupIds,
                userIds: _userIds,
                audiencePreview: _audiencePreview,
                studentsRepository: _studentsRepository,
                onChanged: _markDirty,
                onCategoryChanged: (value) {
                  setState(() => _selectedCategoryId = value);
                  _markDirty();
                },
                onAudienceModeChanged: (value) {
                  setState(() {
                    _audienceMode = value;
                    _audiencePreview = null;
                  });
                  _markDirty();
                },
                onAudienceSelectionChanged:
                    ({required groupIds, required userIds}) {
                      setState(() {
                        _groupIds = groupIds;
                        _userIds = userIds;
                        _audiencePreview = null;
                      });
                      _markDirty();
                    },
                onPreviewAudience: _previewAudience,
                onAddBlock: _addBlock,
                onUpdateBlock: _updateBlock,
                onRemoveBlock: _removeBlock,
                onMoveBlock: _moveBlock,
                onDuplicateBlock: _duplicateBlock,
                onArchive: isArchived ? null : _archive,
                onRestoreArchived: isArchived ? _unarchive : null,
                onSafeDelete: isArchived ? _safeDelete : null,
                onPromoteDemo: selected.origin == ContentOrigin.demo
                    ? _promoteDemo
                    : null,
                onBeginEdit: !selected.isDraft && !isArchived
                    ? _beginEdit
                    : null,
                onResolveCorrection: _resolveCorrection,
              ),
      ),
    );
  }
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.title,
    required this.iconKey,
    required this.shortText,
    required this.sortOrder,
    required this.categoryId,
    required this.audienceMode,
    required this.groupIds,
    required this.userIds,
    required this.blocksWire,
  });

  final String title;
  final String iconKey;
  final String shortText;
  final String sortOrder;
  final String? categoryId;
  final String audienceMode;
  final List<String> groupIds;
  final List<String> userIds;
  final List<String> blocksWire;

  @override
  bool operator ==(Object other) {
    return other is _EditorSnapshot &&
        other.title == title &&
        other.iconKey == iconKey &&
        other.shortText == shortText &&
        other.sortOrder == sortOrder &&
        other.categoryId == categoryId &&
        other.audienceMode == audienceMode &&
        _listEq(other.groupIds, groupIds) &&
        _listEq(other.userIds, userIds) &&
        _listEq(other.blocksWire, blocksWire);
  }

  @override
  int get hashCode => Object.hash(
    title,
    iconKey,
    shortText,
    sortOrder,
    categoryId,
    audienceMode,
    Object.hashAll(groupIds),
    Object.hashAll(userIds),
    Object.hashAll(blocksWire),
  );
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _ReferencePhonePreview extends StatefulWidget {
  const _ReferencePhonePreview({
    required this.categories,
    required this.articles,
    required this.selectedId,
    required this.onArticleSelected,
    this.liveDraft,
  });

  final List<ReferenceCategory> categories;
  final List<ManagedReferenceArticle> articles;
  final String? selectedId;
  final ManagedReferenceArticle? liveDraft;
  final ValueChanged<ManagedReferenceArticle> onArticleSelected;

  @override
  State<_ReferencePhonePreview> createState() => _ReferencePhonePreviewState();
}

class _ReferencePhonePreviewState extends State<_ReferencePhonePreview> {
  bool _showArticle = false;

  ManagedReferenceArticle? get _opened {
    if (widget.liveDraft != null && widget.liveDraft!.id == widget.selectedId) {
      return widget.liveDraft;
    }
    for (final article in widget.articles) {
      if (article.id == widget.selectedId) return article;
    }
    return widget.liveDraft;
  }

  @override
  void didUpdateWidget(covariant _ReferencePhonePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId) {
      // Keep mode; selection syncs left/center/right.
    }
  }

  @override
  Widget build(BuildContext context) {
    final opened = _opened;
    return PhonePreviewFrame(
      child: Theme(
        data: studentPlatformLightTheme(),
        child: Column(
          children: [
            Material(
              color: const Color(0xFFF0F1F6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 40, 8, 6),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Список', softWrap: false),
                      icon: Icon(Icons.list_alt_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Статья', softWrap: false),
                      icon: Icon(Icons.article_outlined, size: 16),
                    ),
                  ],
                  selected: {_showArticle},
                  onSelectionChanged: (value) {
                    if (value.isEmpty) return;
                    setState(() => _showArticle = value.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _showArticle && opened != null
                  ? StudentReferenceArticleDetail(
                      article: opened,
                      showDemoBadge: opened.showDemoBadge,
                      onBack: () => setState(() => _showArticle = false),
                    )
                  : StudentReferenceBrowseView(
                      categories: widget.categories,
                      articles: widget.articles,
                      selectedArticleId: widget.selectedId,
                      onArticleTap: (article) {
                        widget.onArticleSelected(article);
                        setState(() => _showArticle = true);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferencePropertiesPanel extends StatelessWidget {
  const _ReferencePropertiesPanel({
    required this.selected,
    required this.categories,
    required this.corrections,
    required this.canWrite,
    required this.canPublish,
    required this.editingWorkingDraft,
    required this.busy,
    required this.titleController,
    required this.iconKeyController,
    required this.shortTextController,
    required this.sortOrderController,
    required this.selectedCategoryId,
    required this.blocks,
    required this.audienceMode,
    required this.groupIds,
    required this.userIds,
    required this.audiencePreview,
    required this.studentsRepository,
    required this.onChanged,
    required this.onCategoryChanged,
    required this.onAudienceModeChanged,
    required this.onAudienceSelectionChanged,
    required this.onPreviewAudience,
    required this.onAddBlock,
    required this.onUpdateBlock,
    required this.onRemoveBlock,
    required this.onMoveBlock,
    required this.onDuplicateBlock,
    required this.onArchive,
    required this.onRestoreArchived,
    required this.onSafeDelete,
    required this.onPromoteDemo,
    this.onBeginEdit,
    required this.onResolveCorrection,
  });

  final ReferenceArticleItem selected;
  final List<ReferenceCategoryItem> categories;
  final List<ReferenceCorrectionItem> corrections;
  final bool canWrite;
  final bool canPublish;
  final bool editingWorkingDraft;
  final bool busy;
  final TextEditingController titleController;
  final TextEditingController iconKeyController;
  final TextEditingController shortTextController;
  final TextEditingController sortOrderController;
  final String? selectedCategoryId;
  final List<ReferenceBlock> blocks;
  final String audienceMode;
  final List<String> groupIds;
  final List<String> userIds;
  final ReferenceAudiencePreview? audiencePreview;
  final StudentsRepository studentsRepository;
  final VoidCallback onChanged;
  final ValueChanged<String?> onCategoryChanged;
  final ValueChanged<String> onAudienceModeChanged;
  final void Function({
    required List<String> groupIds,
    required List<String> userIds,
  })
  onAudienceSelectionChanged;
  final VoidCallback onPreviewAudience;
  final ValueChanged<String> onAddBlock;
  final void Function(int index, ReferenceBlock block) onUpdateBlock;
  final ValueChanged<int> onRemoveBlock;
  final void Function(int index, int delta) onMoveBlock;
  final ValueChanged<int> onDuplicateBlock;
  final VoidCallback? onArchive;
  final VoidCallback? onRestoreArchived;
  final VoidCallback? onSafeDelete;
  final VoidCallback? onPromoteDemo;
  final VoidCallback? onBeginEdit;
  final Future<void> Function(ReferenceCorrectionItem item, String action)
  onResolveCorrection;

  bool get _editable =>
      canWrite &&
      (selected.status == ReferenceArticleStatus.draft || editingWorkingDraft);

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _textField(titleController, 'Заголовок'),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: selectedCategoryId,
            decoration: const InputDecoration(labelText: 'Категория'),
            items: [
              for (final category in categories)
                DropdownMenuItem(
                  value: category.id,
                  child: Text(category.title),
                ),
            ],
            onChanged: _editable ? onCategoryChanged : null,
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContentIconPickerField(
              selectedKey: iconKeyController.text.trim().isEmpty
                  ? null
                  : iconKeyController.text.trim(),
              enabled: _editable,
              onChanged: (key) {
                iconKeyController.text = key ?? '';
                onChanged();
              },
            ),
          ),
          _textField(shortTextController, 'Краткое описание', maxLines: 3),
          _textField(sortOrderController, 'Порядок сортировки'),
          const SizedBox(height: 12),
          _ReferenceBlocksEditor(
            blocks: blocks,
            enabled: _editable,
            contentItemId: selected.id,
            onAdd: onAddBlock,
            onUpdate: onUpdateBlock,
            onRemove: onRemoveBlock,
            onMove: onMoveBlock,
            onDuplicate: onDuplicateBlock,
          ),
          const Divider(height: 24),
          Text(
            'Аудитория',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: audienceMode,
            decoration: const InputDecoration(labelText: 'Кому показывать'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Всем')),
              DropdownMenuItem(value: 'groups', child: Text('Группам')),
              DropdownMenuItem(value: 'users', child: Text('Пользователям')),
              DropdownMenuItem(
                value: 'groups_and_users',
                child: Text('Группам и пользователям'),
              ),
            ],
            onChanged: !_editable
                ? null
                : (value) => onAudienceModeChanged(value ?? 'all'),
          ),
          ContentAudienceSelectors(
            studentsRepository: studentsRepository,
            audienceMode: audienceMode,
            selectedGroupIds: groupIds,
            selectedUserIds: userIds,
            enabled: _editable,
            onChanged: onAudienceSelectionChanged,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : onPreviewAudience,
            icon: const Icon(Icons.groups_rounded),
            label: Text(
              audiencePreview == null
                  ? 'Предпросмотр охвата'
                  : 'Охват: ${audiencePreview!.recipientCount}',
            ),
          ),
          const Divider(height: 24),
          if (onBeginEdit != null && !editingWorkingDraft)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton.icon(
                onPressed: busy ? null : onBeginEdit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Редактировать'),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onPromoteDemo != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onPromoteDemo,
                  icon: const Icon(Icons.upgrade_rounded),
                  label: const Text('Сделать обычной'),
                ),
              if (onArchive != null)
                OutlinedButton.icon(
                  onPressed: busy || !canPublish ? null : onArchive,
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('В архив'),
                ),
              if (onRestoreArchived != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onRestoreArchived,
                  icon: const Icon(Icons.unarchive_outlined),
                  label: const Text('Восстановить'),
                ),
              if (onSafeDelete != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onSafeDelete,
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Удалить навсегда'),
                ),
            ],
          ),
          ExpansionTile(
            title: Text('Обращения об ошибках (${corrections.length})'),
            children: [
              if (corrections.isEmpty)
                const ListTile(
                  dense: true,
                  title: Text('Открытых обращений нет.'),
                )
              else
                for (final correction in corrections)
                  ListTile(
                    dense: true,
                    title: Text(correction.contentTitle),
                    subtitle: Text(correction.note),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () =>
                                    onResolveCorrection(correction, 'resolve'),
                          child: const Text('Закрыть'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => onResolveCorrection(correction, 'reject'),
                          child: const Text('Отклонить'),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
          ContentTechnicalPanel(
            children: [
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Версия строки'),
                subtitle: Text('${selected.rowVersion}'),
              ),
              if (selected.legacyKey != null)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Legacy key'),
                  subtitle: Text(selected.legacyKey!),
                ),
              _textField(iconKeyController, 'icon_key'),
              _textField(sortOrderController, 'sort_order'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        enabled: _editable,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

class _VersionHistoryDialog extends StatelessWidget {
  const _VersionHistoryDialog({required this.versions});

  final List<ReferenceVersionInfo> versions;

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
            return ListTile(
              leading: CircleAvatar(child: Text('${version.versionNumber}')),
              title: Text('Версия ${version.versionNumber}'),
              subtitle: Text(
                '${version.title} · ${version.status.russianLabel}',
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

class _ReferenceBlocksEditor extends StatelessWidget {
  const _ReferenceBlocksEditor({
    required this.blocks,
    required this.enabled,
    required this.contentItemId,
    required this.onAdd,
    required this.onUpdate,
    required this.onRemove,
    required this.onMove,
    required this.onDuplicate,
  });

  final List<ReferenceBlock> blocks;
  final bool enabled;
  final String? contentItemId;
  final ValueChanged<String> onAdd;
  final void Function(int index, ReferenceBlock block) onUpdate;
  final ValueChanged<int> onRemove;
  final void Function(int index, int delta) onMove;
  final ValueChanged<int> onDuplicate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Блоки контента',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (enabled)
              PopupMenuButton<String>(
                tooltip: 'Добавить блок',
                onSelected: onAdd,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'text', child: Text('Текст')),
                  PopupMenuItem(value: 'image', child: Text('Изображение')),
                  PopupMenuItem(value: 'file', child: Text('Файл')),
                  PopupMenuItem(value: 'link', child: Text('Ссылка')),
                  PopupMenuItem(value: 'cta', child: Text('CTA')),
                  // Schema v3 blocks stay feature-gated until owner enables
                  // after the compatible Mobile build is released.
                  if (bool.fromEnvironment(
                    'ADMIN_REFERENCE_V3_BLOCKS',
                    defaultValue: false,
                  )) ...[
                    PopupMenuItem(value: 'heading', child: Text('Заголовок')),
                    PopupMenuItem(value: 'info', child: Text('Инфо')),
                    PopupMenuItem(
                      value: 'warning',
                      child: Text('Предупреждение'),
                    ),
                    PopupMenuItem(value: 'list', child: Text('Список')),
                  ],
                ],
                icon: const Icon(Icons.add_rounded),
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
            onDuplicate: () => onDuplicate(i),
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
    required this.onDuplicate,
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
  final VoidCallback onDuplicate;

  static String _typeLabelRu(String type) => switch (type) {
    'text' => 'Текст',
    'image' => 'Изображение',
    'file' => 'Файл',
    'link' => 'Ссылка',
    'cta' => 'CTA',
    'heading' => 'Заголовок',
    'info' => 'Инфо',
    'warning' => 'Предупреждение',
    'list' => 'Список',
    _ => type,
  };

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
      case ReferenceHeadingBlock(:final text, :final level):
        _primary = TextEditingController(text: text);
        _secondary = TextEditingController(text: '$level');
        _tertiary = TextEditingController();
      case ReferenceInfoBlock(:final text):
      case ReferenceWarningBlock(:final text):
        _primary = TextEditingController(text: text);
        _secondary = TextEditingController();
        _tertiary = TextEditingController();
      case ReferenceListBlock(:final style, :final items):
        _primary = TextEditingController(text: items.join('\n'));
        _secondary = TextEditingController(text: style);
        _tertiary = TextEditingController();
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
                Expanded(
                  child: Text(
                    'Блок ${widget.index + 1}: ${_ReferenceBlockTile._typeLabelRu(block.type)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                if (widget.enabled)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Дублировать',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onDuplicate,
                        icon: const Icon(Icons.copy_outlined),
                      ),
                      IconButton(
                        tooltip: 'Выше',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.canMoveUp ? widget.onMoveUp : null,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: 'Ниже',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.canMoveDown
                            ? widget.onMoveDown
                            : null,
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      IconButton(
                        tooltip: 'Удалить',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onRemove,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
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
                  labelText: 'Текст',
                  alignLabelWithHint: true,
                ),
                onChanged: (value) =>
                    widget.onUpdate(ReferenceTextBlock(text: value)),
              ),
              ReferenceImageBlock() => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_primary.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Файл загружен',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF5C6370),
                        ),
                      ),
                    ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(
                      labelText: 'Подпись (опц.)',
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
                        onPressed: _uploading
                            ? null
                            : () => _uploadMedia(
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
                        icon: _uploading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.upload_file),
                        label: Text(
                          _primary.text.trim().isEmpty
                              ? 'Загрузить изображение'
                              : 'Заменить изображение',
                        ),
                      ),
                    ),
                  if (_primary.text.trim().isNotEmpty)
                    ContentTechnicalPanel(
                      children: [
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('ID файла'),
                          subtitle: Text(_primary.text),
                        ),
                      ],
                    ),
                ],
              ),
              ReferenceFileBlock() => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_primary.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Файл загружен',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF5C6370),
                        ),
                      ),
                    ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(
                      labelText: 'Название (опц.)',
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
                        onPressed: _uploading
                            ? null
                            : () => _uploadMedia(
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
                        icon: _uploading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.upload_file),
                        label: Text(
                          _primary.text.trim().isEmpty
                              ? 'Загрузить файл'
                              : 'Заменить файл',
                        ),
                      ),
                    ),
                  if (_primary.text.trim().isNotEmpty)
                    ContentTechnicalPanel(
                      children: [
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('ID файла'),
                          subtitle: Text(_primary.text),
                        ),
                      ],
                    ),
                ],
              ),
              ReferenceLinkBlock() => Column(
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'Подпись'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceLinkBlock(label: value, url: _secondary.text),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    decoration: const InputDecoration(labelText: 'URL'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceLinkBlock(label: _primary.text, url: value),
                    ),
                  ),
                ],
              ),
              ReferenceCtaBlock(:final cta) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'Подпись'),
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
                  const SizedBox(height: 8),
                  ContentActionPicker(
                    selection: contentActionFromLegacy(
                      ctaAction: (cta.url != null && cta.url!.isNotEmpty)
                          ? 'url'
                          : 'route',
                      ctaRoute: _secondary.text,
                      ctaUrl: _tertiary.text,
                    ),
                    enabled: widget.enabled,
                    allowedKinds: const [
                      ContentActionKind.appScreen,
                      ContentActionKind.externalUrl,
                      ContentActionKind.none,
                    ],
                    onChanged: (action) {
                      applyContentActionToLegacy(
                        action: action,
                        onCtaActionChanged: (_) {},
                        onCtaRouteChanged: (value) {
                          _secondary.text = value;
                          _tertiary.text = '';
                          widget.onUpdate(
                            ReferenceCtaBlock(
                              cta: ReferenceArticleCta(
                                label: _primary.text,
                                route: value.trim().isEmpty
                                    ? null
                                    : value.trim(),
                              ),
                            ),
                          );
                        },
                        onCtaUrlChanged: (value) {
                          _tertiary.text = value;
                          _secondary.text = '';
                          widget.onUpdate(
                            ReferenceCtaBlock(
                              cta: ReferenceArticleCta(
                                label: _primary.text,
                                url: value.trim().isEmpty ? null : value.trim(),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
              ReferenceHeadingBlock() => Column(
                children: [
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    decoration: const InputDecoration(labelText: 'Текст'),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceHeadingBlock(
                        text: value,
                        level: int.tryParse(_secondary.text.trim()) ?? 1,
                      ),
                    ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _secondary,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Уровень (1–3)',
                    ),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceHeadingBlock(
                        text: _primary.text,
                        level: int.tryParse(value.trim()) ?? 1,
                      ),
                    ),
                  ),
                ],
              ),
              ReferenceInfoBlock() => TextField(
                enabled: widget.enabled,
                controller: _primary,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Текст',
                  alignLabelWithHint: true,
                ),
                onChanged: (value) =>
                    widget.onUpdate(ReferenceInfoBlock(text: value)),
              ),
              ReferenceWarningBlock() => TextField(
                enabled: widget.enabled,
                controller: _primary,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Текст',
                  alignLabelWithHint: true,
                ),
                onChanged: (value) =>
                    widget.onUpdate(ReferenceWarningBlock(text: value)),
              ),
              ReferenceListBlock() => Column(
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _secondary.text.isEmpty
                        ? 'bullet'
                        : _secondary.text,
                    decoration: const InputDecoration(labelText: 'Стиль'),
                    items: const [
                      DropdownMenuItem(
                        value: 'bullet',
                        child: Text('Маркированный'),
                      ),
                      DropdownMenuItem(
                        value: 'numbered',
                        child: Text('Нумерованный'),
                      ),
                    ],
                    onChanged: !widget.enabled
                        ? null
                        : (value) => widget.onUpdate(
                            ReferenceListBlock(
                              style: value ?? 'bullet',
                              items: _primary.text
                                  .split('\n')
                                  .map((e) => e.trim())
                                  .where((e) => e.isNotEmpty)
                                  .toList(),
                            ),
                          ),
                  ),
                  TextField(
                    enabled: widget.enabled,
                    controller: _primary,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'Пункты (по одному в строке)',
                      alignLabelWithHint: true,
                    ),
                    onChanged: (value) => widget.onUpdate(
                      ReferenceListBlock(
                        style: _secondary.text.isEmpty
                            ? 'bullet'
                            : _secondary.text,
                        items: value
                            .split('\n')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList(),
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
