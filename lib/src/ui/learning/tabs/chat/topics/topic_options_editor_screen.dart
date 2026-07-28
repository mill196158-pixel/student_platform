// =============================
// FILE: lib/src/ui/learning/tabs/chat/topics/topic_options_editor_screen.dart
// =============================
//
// Stage 13.12 continuation — modern editor for an already-PUBLISHED topic
// selection (title/description/deadline/allow-change + the topic list
// itself). Replaces the old `topic_selection_detail_screen.dart` AlertDialog
// edit flow with the same New-Assignment-style hero header, soft cards,
// bottom-sheet editors, drag reorder, multi-select bulk delete, undo-delete
// and duplicate warnings used by `create_topic_selection_screen.dart` /
// `topic_list_review_screen.dart`.
//
// Opened from [UnifiedTaskDetailsScreen] only when the caller has already
// resolved `canManage` (organizer) or `canEditOwnBeforeActivity` (author,
// before any member has picked a topic) — ordinary members never see the
// entry point. Every mutation still goes through server RPCs that enforce
// the same rule again (`private.assert_topic_selection_mutable`), so this
// screen is a UX convenience, not the source of truth for permissions.
//
// All mutating RPCs (`update_topic_selection`, `update_topic_option`,
// `reorder_topic_options`, `remove_topic_option`,
// `add_topic_option_with_version`) share one optimistic-concurrency token:
// the selection's `row_version`. A `version_conflict` from any of them
// surfaces a dismissible banner with a "Обновить" action that re-fetches
// fresh selection + options via `get_task_details` before the user retries.
import 'package:flutter/material.dart';

import '../../../../common/keyboard_dismiss_scope.dart';
import '../data/chat_group_actions_repository.dart';

/// Maps known server RPC error codes (see the Stage 13.12 SQL migration:
/// `version_conflict`, `option_occupied`, `selection_unavailable`,
/// `forbidden`, `invalid_capacity`, `reorder_set_mismatch`,
/// `title_required`) to friendly, never-technical Russian copy.
String friendlyTopicEditError(Object e) {
  final msg = e.toString().toLowerCase();
  if (msg.contains('version_conflict')) {
    return 'Список обновился на сервере. Обновите данные и повторите.';
  }
  if (msg.contains('option_occupied')) {
    return 'Тему уже выбрали — уменьшить места ниже занятых или удалить её нельзя.';
  }
  if (msg.contains('selection_unavailable')) {
    return 'Выбор темы закрыт или недоступен — редактирование невозможно.';
  }
  if (msg.contains('reorder_set_mismatch')) {
    return 'Список тем изменился на сервере — обновите порядок и повторите.';
  }
  if (msg.contains('invalid_capacity')) {
    return 'Укажите количество мест не меньше числа уже выбравших.';
  }
  if (msg.contains('title_required')) {
    return 'Введите название темы.';
  }
  if (msg.contains('forbidden') || msg.contains('42501')) {
    return 'Недостаточно прав для этого действия.';
  }
  return 'Не удалось сохранить изменения. Попробуйте ещё раз.';
}

/// A single published topic option as shown/edited on this screen.
class TopicEditRow {
  const TopicEditRow({
    required this.id,
    required this.title,
    required this.capacity,
    this.taken = 0,
    this.rowVersion,
  });

  final String id;
  final String title;
  final int capacity;
  final int taken;
  final int? rowVersion;

  bool get isOccupied => taken > 0;

  TopicEditRow copyWith({String? title, int? capacity}) => TopicEditRow(
        id: id,
        title: title ?? this.title,
        capacity: capacity ?? this.capacity,
        taken: taken,
        rowVersion: rowVersion,
      );

  factory TopicEditRow.fromJson(Map<String, dynamic> json) => TopicEditRow(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        capacity: _asInt(json['capacity'], fallback: 1),
        taken: _asInt(json['taken']),
        rowVersion:
            json['row_version'] == null ? null : _asInt(json['row_version']),
      );

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

/// Pushes [TopicOptionsEditorScreen] and returns `true` when any change was
/// saved (caller should refresh its own view of the selection).
Future<bool?> openTopicOptionsEditor(
  BuildContext context, {
  required String chatId,
  required String selectionId,
  required String title,
  String description = '',
  DateTime? deadlineAt,
  bool allowChange = true,
  required int selectionRowVersion,
  required List<TopicEditRow> options,
  bool canManage = false,
  bool canEditOwnBeforeActivity = false,
  ChatGroupActionsRepository? repository,
}) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => TopicOptionsEditorScreen(
        chatId: chatId,
        selectionId: selectionId,
        title: title,
        description: description,
        deadlineAt: deadlineAt,
        allowChange: allowChange,
        selectionRowVersion: selectionRowVersion,
        options: options,
        canManage: canManage,
        canEditOwnBeforeActivity: canEditOwnBeforeActivity,
        repository: repository,
      ),
    ),
  );
}

class TopicOptionsEditorScreen extends StatefulWidget {
  const TopicOptionsEditorScreen({
    super.key,
    required this.chatId,
    required this.selectionId,
    required this.title,
    this.description = '',
    this.deadlineAt,
    this.allowChange = true,
    required this.selectionRowVersion,
    this.options = const [],
    this.canManage = false,
    this.canEditOwnBeforeActivity = false,
    this.repository,
  });

  final String chatId;
  final String selectionId;
  final String title;
  final String description;
  final DateTime? deadlineAt;
  final bool allowChange;
  final int selectionRowVersion;
  final List<TopicEditRow> options;
  final bool canManage;
  final bool canEditOwnBeforeActivity;
  final ChatGroupActionsRepository? repository;

  @override
  State<TopicOptionsEditorScreen> createState() =>
      _TopicOptionsEditorScreenState();
}

class _TopicOptionsEditorScreenState extends State<TopicOptionsEditorScreen> {
  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository();

  late final TextEditingController _titleCtrl =
      TextEditingController(text: widget.title);
  late final TextEditingController _descCtrl =
      TextEditingController(text: widget.description);
  final _searchCtrl = TextEditingController();

  late int _selectionVersion = widget.selectionRowVersion;
  DateTime? _deadline;
  late bool _allowChange = widget.allowChange;
  late List<TopicEditRow> _options = List.of(widget.options);

  bool get _canEdit => widget.canManage || widget.canEditOwnBeforeActivity;

  bool _metaDirty = false;
  bool _savingMeta = false;
  bool _acting = false;
  bool _reloading = false;
  bool _conflict = false;
  String? _conflictMessage;
  bool _changed = false;
  bool _selecting = false;
  final Set<String> _selectedIds = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _deadline = widget.deadlineAt;
    _titleCtrl.addListener(_markMetaDirty);
    _descCtrl.addListener(_markMetaDirty);
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _markMetaDirty() {
    if (!_metaDirty) setState(() => _metaDirty = true);
  }

  List<TopicEditRow> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _options;
    return _options.where((o) => o.title.toLowerCase().contains(q)).toList();
  }

  Set<String> get _duplicateKeys {
    final seen = <String>{};
    final dupes = <String>{};
    for (final o in _options) {
      final key = o.title.trim().toLowerCase();
      if (key.isEmpty) continue;
      if (!seen.add(key)) dupes.add(key);
    }
    return dupes;
  }

  void _handleEditError(Object e) {
    final message = friendlyTopicEditError(e);
    final isConflict = e.toString().toLowerCase().contains('version_conflict');
    if (isConflict) {
      setState(() {
        _conflict = true;
        _conflictMessage = message;
      });
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _reload() async {
    if (_reloading) return;
    setState(() => _reloading = true);
    try {
      final details = await _repo.getTaskDetails(
        chatId: widget.chatId,
        kind: 'topic_selection',
        entityId: widget.selectionId,
      );
      if (!mounted) return;
      if (details['available'] != true) {
        setState(() {
          _reloading = false;
          _conflictMessage = 'Выбор темы больше недоступен.';
        });
        return;
      }
      final options = (details['options'] as List?)
              ?.whereType<Map>()
              .map((e) => TopicEditRow.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const <TopicEditRow>[];
      setState(() {
        _titleCtrl.text = (details['title'] ?? '').toString();
        _descCtrl.text = (details['description'] ?? '').toString();
        _deadline =
            DateTime.tryParse((details['deadline_at'] ?? '').toString());
        _allowChange = details['allow_change'] != false;
        final version = details['row_version'];
        if (version != null) {
          _selectionVersion = version is int
              ? version
              : int.tryParse(version.toString()) ?? _selectionVersion;
        }
        _options = options;
        _metaDirty = false;
        _conflict = false;
        _conflictMessage = null;
        _reloading = false;
        _selecting = false;
        _selectedIds.clear();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _reloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось обновить данные')),
      );
    }
  }

  Future<void> _saveMeta() async {
    if (!_canEdit || _savingMeta) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название выбора темы')),
      );
      return;
    }
    KeyboardDismissScope.unfocus(context);
    setState(() => _savingMeta = true);
    try {
      final res = await _repo.updateTopicSelection(
        selectionId: widget.selectionId,
        expectedVersion: _selectionVersion,
        title: title,
        description: _descCtrl.text.trim(),
        deadlineAt: _deadline,
        allowChange: _allowChange,
      );
      if (!mounted) return;
      setState(() {
        final version = res['row_version'];
        if (version is int) _selectionVersion = version;
        _metaDirty = false;
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сохранено')),
      );
    } catch (e) {
      if (!mounted) return;
      _handleEditError(e);
    } finally {
      if (mounted) setState(() => _savingMeta = false);
    }
  }

  Future<void> _pickDeadline() async {
    KeyboardDismissScope.unfocus(context);
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
      initialDate: _deadline ?? now,
      helpText: 'Выбрать до',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _deadline ?? now.add(const Duration(hours: 2)),
      ),
      helpText: 'Выбрать до',
      cancelText: 'Отмена',
      confirmText: 'Готово',
    );
    if (time == null || !mounted) return;
    setState(() {
      _deadline = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
      );
      _metaDirty = true;
    });
  }

  Future<_OptionDraft?> _showOptionEditorSheet({TopicEditRow? existing}) {
    return showModalBottomSheet<_OptionDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OptionEditorSheet(
        initialTitle: existing?.title ?? '',
        initialCapacity: existing?.capacity ?? 1,
        minCapacity: existing?.taken ?? 0,
        isNew: existing == null,
      ),
    );
  }

  Future<void> _addOption() async {
    if (!_canEdit || _acting) return;
    final draft = await _showOptionEditorSheet();
    if (draft == null || !mounted) return;
    setState(() => _acting = true);
    try {
      final res = await _repo.addTopicOptionWithVersion(
        selectionId: widget.selectionId,
        title: draft.title,
        capacity: draft.capacity,
        expectedVersion: _selectionVersion,
      );
      if (!mounted) return;
      final version = res['row_version'];
      final newId = (res['option_id'] ?? '').toString();
      setState(() {
        if (version is int) _selectionVersion = version;
        if (newId.isNotEmpty) {
          _options = [
            ..._options,
            TopicEditRow(
                id: newId, title: draft.title, capacity: draft.capacity),
          ];
        }
        _changed = true;
      });
    } catch (e) {
      if (!mounted) return;
      _handleEditError(e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _editOption(TopicEditRow row) async {
    if (!_canEdit || _acting) return;
    final draft = await _showOptionEditorSheet(existing: row);
    if (draft == null || !mounted) return;
    setState(() => _acting = true);
    try {
      final res = await _repo.updateTopicOption(
        optionId: row.id,
        expectedVersion: _selectionVersion,
        title: draft.title,
        capacity: draft.capacity,
      );
      if (!mounted) return;
      final version = res['row_version'];
      setState(() {
        if (version is int) _selectionVersion = version;
        _options = [
          for (final o in _options)
            if (o.id == row.id)
              o.copyWith(title: draft.title, capacity: draft.capacity)
            else
              o,
        ];
        _changed = true;
      });
    } catch (e) {
      if (!mounted) return;
      _handleEditError(e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _deleteOption(TopicEditRow row) async {
    if (!_canEdit || _acting) return;
    if (row.isOccupied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Тему уже выбрали — сначала уточните с участником'),
        ),
      );
      return;
    }
    final index = _options.indexWhere((o) => o.id == row.id);
    if (index < 0) return;
    setState(() => _options.removeAt(index));

    var undone = false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Тема «${row.title}» удалена'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: () {
            undone = true;
            if (!mounted) return;
            setState(() {
              final at = index.clamp(0, _options.length);
              _options.insert(at, row);
            });
          },
        ),
      ),
    );

    await Future.delayed(const Duration(seconds: 4));
    if (undone || !mounted) return;

    try {
      final res = await _repo.removeTopicOption(
        optionId: row.id,
        expectedVersion: _selectionVersion,
      );
      if (!mounted) return;
      final version = res['row_version'];
      setState(() {
        if (version is int) _selectionVersion = version;
        _changed = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _options.insert(index.clamp(0, _options.length), row));
      _handleEditError(e);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (!_canEdit || _acting) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target == oldIndex) return;
    final previous = List<TopicEditRow>.of(_options);
    setState(() {
      final item = _options.removeAt(oldIndex);
      _options.insert(target, item);
      _acting = true;
    });
    try {
      final res = await _repo.reorderTopicOptions(
        selectionId: widget.selectionId,
        expectedVersion: _selectionVersion,
        optionIds: [for (final o in _options) o.id],
      );
      if (!mounted) return;
      final version = res['row_version'];
      setState(() {
        if (version is int) _selectionVersion = version;
        _changed = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _options = previous);
      _handleEditError(e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<bool> _confirmBottomSheet({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ConfirmSheet(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
      ),
    );
    return result == true;
  }

  Future<void> _bulkDelete() async {
    if (_selectedIds.isEmpty || _acting) return;
    final targets = _options.where((o) => _selectedIds.contains(o.id)).toList();
    final occupied = targets.where((o) => o.isOccupied).toList();
    final removable = targets.where((o) => !o.isOccupied).toList();

    if (occupied.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${occupied.length} из выбранных тем уже заняты — их нельзя удалить',
          ),
        ),
      );
    }
    if (removable.isEmpty) return;

    final confirmed = await _confirmBottomSheet(
      title: 'Удалить темы?',
      message: 'Будет удалено тем: ${removable.length}. Это действие '
          'нельзя отменить.',
      confirmLabel: 'Удалить',
    );
    if (!confirmed || !mounted) return;

    setState(() => _acting = true);
    var version = _selectionVersion;
    final removedIds = <String>[];
    for (final o in removable) {
      try {
        final res = await _repo.removeTopicOption(
          optionId: o.id,
          expectedVersion: version,
        );
        final v = res['row_version'];
        if (v is int) version = v;
        removedIds.add(o.id);
      } catch (e) {
        if (mounted) _handleEditError(e);
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _selectionVersion = version;
      _options = _options.where((o) => !removedIds.contains(o.id)).toList();
      _selectedIds.clear();
      _selecting = false;
      _acting = false;
      if (removedIds.isNotEmpty) _changed = true;
    });
    if (removedIds.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Удалено тем: ${removedIds.length}')),
      );
    }
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final filtered = _filtered;
    final duplicates = _duplicateKeys;
    final canReorder = _canEdit && _query.trim().isEmpty && !_selecting;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (_, __) {},
      child: Scaffold(
        backgroundColor: cs.surface,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: KeyboardDismissScope(
                  child: CustomScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    tooltip: 'Назад',
                                    onPressed: () =>
                                        Navigator.of(context).pop(_changed),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                                  const Spacer(),
                                  if (!_selecting && _options.isNotEmpty)
                                    TextButton(
                                      onPressed: _toggleSelecting,
                                      child: const Text('Выбрать'),
                                    )
                                  else if (_selecting)
                                    TextButton(
                                      onPressed: _toggleSelecting,
                                      child: const Text('Готово'),
                                    ),
                                ],
                              ),
                              const _EditorHeroHeader(),
                              const SizedBox(height: 16),
                              if (_conflict) ...[
                                _ConflictBanner(
                                  message: _conflictMessage ??
                                      'Список обновился на сервере.',
                                  loading: _reloading,
                                  onRefresh: _reload,
                                ),
                                const SizedBox(height: 12),
                              ],
                              _SectionLabel(
                                icon: Icons.edit_note_rounded,
                                label: 'О выборе',
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _titleCtrl,
                                enabled: _canEdit,
                                textInputAction: TextInputAction.next,
                                decoration: _fieldDecoration(
                                  label: 'Название',
                                  icon: Icons.title_rounded,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _descCtrl,
                                enabled: _canEdit,
                                minLines: 2,
                                maxLines: 4,
                                textInputAction: TextInputAction.done,
                                onEditingComplete: () =>
                                    KeyboardDismissScope.unfocus(context),
                                decoration: _fieldDecoration(
                                  label: 'Описание',
                                  icon: Icons.notes_rounded,
                                  alignLabelWithHint: true,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _SectionLabel(
                                icon: Icons.event_available_rounded,
                                label: 'Выбрать до',
                                trailing: _deadline == null
                                    ? 'Не задан'
                                    : _fmt(_deadline!),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed:
                                          _canEdit ? _pickDeadline : null,
                                      icon: const Icon(
                                          Icons.calendar_month_rounded,
                                          size: 18),
                                      label: Text(
                                        _deadline == null
                                            ? 'Выбрать дату'
                                            : _fmt(_deadline!),
                                      ),
                                    ),
                                  ),
                                  if (_deadline != null) ...[
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: 'Сбросить',
                                      onPressed: _canEdit
                                          ? () => setState(() {
                                                _deadline = null;
                                                _metaDirty = true;
                                              })
                                          : null,
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              _SoftSwitchTile(
                                title: 'Разрешить смену темы',
                                value: _allowChange,
                                onChanged: _canEdit
                                    ? (v) => setState(() {
                                          _allowChange = v;
                                          _metaDirty = true;
                                        })
                                    : null,
                              ),
                              const SizedBox(height: 18),
                              _SectionLabel(
                                icon: Icons.list_alt_rounded,
                                label: 'Темы',
                                trailing: '${_options.length}',
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _searchCtrl,
                                textInputAction: TextInputAction.search,
                                decoration: _fieldDecoration(
                                  label: 'Поиск темы',
                                  icon: Icons.search_rounded,
                                  suffix: _query.isEmpty
                                      ? null
                                      : IconButton(
                                          icon: const Icon(Icons.close_rounded,
                                              size: 18),
                                          onPressed: () {
                                            _searchCtrl.clear();
                                          },
                                        ),
                                ),
                              ),
                              if (duplicates.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                _WarningBanner(
                                  text:
                                      'Похожие названия тем: ${duplicates.length}. '
                                      'Проверьте список перед сохранением.',
                                ),
                              ],
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                      if (_options.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                            child: Text(
                              'Темы пока не добавлены',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: Colors.black45),
                            ),
                          ),
                        )
                      else if (filtered.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                            child: Text(
                              'Темы не найдены',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: Colors.black45),
                            ),
                          ),
                        )
                      else if (canReorder)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          sliver: SliverReorderableList(
                            itemCount: _options.length,
                            onReorder: _reorder,
                            itemBuilder: (context, index) {
                              final row = _options[index];
                              return _OptionRow(
                                key: ValueKey('opt_${row.id}'),
                                row: row,
                                index: index,
                                isDuplicate: duplicates
                                    .contains(row.title.trim().toLowerCase()),
                                selecting: _selecting,
                                selected: _selectedIds.contains(row.id),
                                canEdit: _canEdit,
                                dragHandle: ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(Icons.drag_handle_rounded),
                                ),
                                onTap: _selecting
                                    ? () => _toggleSelect(row.id)
                                    : null,
                                onEdit: () => _editOption(row),
                                onDelete: () => _deleteOption(row),
                              );
                            },
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, i) {
                                final row = filtered[i];
                                final index = _options.indexOf(row);
                                return _OptionRow(
                                  key: ValueKey('opt_${row.id}'),
                                  row: row,
                                  index: index,
                                  isDuplicate: duplicates
                                      .contains(row.title.trim().toLowerCase()),
                                  selecting: _selecting,
                                  selected: _selectedIds.contains(row.id),
                                  canEdit: _canEdit,
                                  dragHandle: null,
                                  onTap: _selecting
                                      ? () => _toggleSelect(row.id)
                                      : null,
                                  onEdit: () => _editOption(row),
                                  onDelete: () => _deleteOption(row),
                                );
                              },
                              childCount: filtered.length,
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: _bottomBar(),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final cs = Theme.of(context).colorScheme;
    if (_selecting) {
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
              top: BorderSide(color: Colors.black.withValues(alpha: 0.06))),
        ),
        child: Row(
          children: [
            TextButton(
                onPressed: _toggleSelecting, child: const Text('Отмена')),
            const Spacer(),
            FilledButton.icon(
              onPressed: (_selectedIds.isEmpty || _acting) ? null : _bulkDelete,
              icon: const Icon(Icons.delete_outline),
              label: Text('Удалить (${_selectedIds.length})'),
              style: FilledButton.styleFrom(backgroundColor: cs.error),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
            top: BorderSide(color: Colors.black.withValues(alpha: 0.06))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_metaDirty) ...[
            FilledButton(
              onPressed: (_canEdit && !_savingMeta) ? _saveMeta : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _savingMeta
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Сохранить изменения'),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            onPressed: _canEdit ? _addOption : null,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Добавить тему'),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
    Widget? suffix,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      labelText: label,
      alignLabelWithHint: alignLabelWithHint,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      filled: true,
      fillColor: const Color(0xFFF6F7FB),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE1E5EF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.black87, width: 1.4),
      ),
    );
  }
}

class _OptionDraft {
  const _OptionDraft(this.title, this.capacity);
  final String title;
  final int capacity;
}

class _OptionEditorSheet extends StatefulWidget {
  const _OptionEditorSheet({
    required this.initialTitle,
    required this.initialCapacity,
    required this.minCapacity,
    required this.isNew,
  });

  final String initialTitle;
  final int initialCapacity;
  final int minCapacity;
  final bool isNew;

  @override
  State<_OptionEditorSheet> createState() => _OptionEditorSheetState();
}

class _OptionEditorSheetState extends State<_OptionEditorSheet> {
  late final _titleCtrl = TextEditingController(text: widget.initialTitle);
  late final _capCtrl =
      TextEditingController(text: widget.initialCapacity.toString());

  @override
  void dispose() {
    _titleCtrl.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название темы')),
      );
      return;
    }
    var capacity = int.tryParse(_capCtrl.text.trim()) ?? widget.initialCapacity;
    if (capacity < widget.minCapacity) capacity = widget.minCapacity;
    if (capacity < 1) capacity = 1;
    Navigator.of(context).pop(_OptionDraft(title, capacity));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Material(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: KeyboardDismissScope(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Text(
                    widget.isNew ? 'Новая тема' : 'Изменить тему',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _titleCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Название'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _capCtrl,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Мест',
                      helperText: widget.minCapacity > 0
                          ? 'Уже выбрали: ${widget.minCapacity}'
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _submit,
                    style:
                        FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(message, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: cs.error),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorHeroHeader extends StatelessWidget {
  const _EditorHeroHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primary.withValues(alpha: 0.14),
              cs.primaryContainer.withValues(alpha: 0.55),
              const Color(0xFFF6F7FB),
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(Icons.edit_note_rounded, color: cs.primary, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Управление темами',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Правки применяются сразу и видны участникам чата',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.black.withValues(alpha: 0.62),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label, this.trailing});
  final IconData icon;
  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w800, color: Colors.black87),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: Colors.black45, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

class _SoftSwitchTile extends StatelessWidget {
  const _SoftSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E5EF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800, color: Colors.black87),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.orange.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({
    required this.message,
    required this.loading,
    required this.onRefresh,
  });

  final String message;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: const Color(0xFFE53935).withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.sync_problem_rounded,
              color: Color(0xFFE53935), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFB71C1C),
                  ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: loading ? null : onRefresh,
            style: FilledButton.styleFrom(backgroundColor: cs.surface),
            child: loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Обновить'),
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.row,
    required this.index,
    required this.isDuplicate,
    required this.selecting,
    required this.selected,
    required this.canEdit,
    required this.dragHandle,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final TopicEditRow row;
  final int index;
  final bool isDuplicate;
  final bool selecting;
  final bool selected;
  final bool canEdit;
  final Widget? dragHandle;
  final VoidCallback? onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.10)
            : const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDuplicate
                    ? Colors.orange.withValues(alpha: 0.55)
                    : const Color(0xFFE1E5EF),
              ),
            ),
            child: Row(
              children: [
                if (selecting)
                  Checkbox(value: selected, onChanged: (_) => onTap?.call())
                else
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: cs.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.title.isEmpty ? 'Без названия' : row.title,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        row.isOccupied
                            ? 'Занято ${row.taken} из ${row.capacity}'
                            : 'Мест: ${row.capacity}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              row.isOccupied ? cs.primary : cs.onSurfaceVariant,
                          fontWeight: row.isOccupied ? FontWeight.w700 : null,
                        ),
                      ),
                      if (isDuplicate) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Похоже на другую тему в списке',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!selecting && canEdit) ...[
                  IconButton(
                    tooltip: 'Изменить',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: row.isOccupied ? 'Тема занята' : 'Удалить',
                    onPressed: onDelete,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: row.isOccupied
                          ? cs.onSurfaceVariant.withValues(alpha: 0.4)
                          : cs.error,
                    ),
                  ),
                  if (dragHandle != null) dragHandle!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
