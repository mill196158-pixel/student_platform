import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../common/keyboard_dismiss_scope.dart';
import '../data/chat_group_actions_repository.dart';
import '../models/chat_group_actions.dart';

/// Opens the modern topic chooser as a tall bottom sheet with search.
Future<void> showTopicSelectionChooser(
  BuildContext context, {
  required String chatId,
  required ChatTopicSelection selection,
  ChatGroupActionsRepository? repository,
  bool canManage = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => TopicSelectionDetailScreen(
      chatId: chatId,
      selection: selection,
      repository: repository,
      canManage: canManage,
      asBottomSheet: true,
    ),
  );
}

/// Modern topic chooser opened from the compact chat bubble.
class TopicSelectionDetailScreen extends StatefulWidget {
  const TopicSelectionDetailScreen({
    super.key,
    required this.chatId,
    required this.selection,
    this.repository,
    this.canManage = false,
    this.asBottomSheet = false,
  });

  final String chatId;
  final ChatTopicSelection selection;
  final ChatGroupActionsRepository? repository;
  final bool canManage;
  final bool asBottomSheet;

  @override
  State<TopicSelectionDetailScreen> createState() =>
      _TopicSelectionDetailScreenState();
}

enum _TopicFilter { free, taken, all }

class _TopicSelectionDetailScreenState
    extends State<TopicSelectionDetailScreen> {
  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository();

  final _searchCtrl = TextEditingController();

  ChatTopicSelection? _selection;
  List<ChatTopicOption> _options = const [];
  List<ChatTopicOption> _lastGoodOptions = const [];
  bool _loading = true;
  String? _error;
  String? _raceMessage;
  bool _acting = false;
  _TopicFilter _filter = _TopicFilter.free;
  String _query = '';
  RealtimeChannel? _channel;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _selection = widget.selection;
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text);
    });
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _refreshDebounce?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    super.dispose();
  }

  void _subscribeRealtime() {
    try {
      final id = widget.selection.id;
      _channel = Supabase.instance.client
          .channel('topic-chooser-$id')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'group_topic_picks',
            filter: PostgresChangeFilter(
              column: 'selection_id',
              type: PostgresChangeFilterType.eq,
              value: id,
            ),
            callback: (_) => _scheduleRefresh(),
          )
          .subscribe();
    } catch (_) {
      // Offline / realtime unavailable — keep last-good UI.
    }
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) unawaited(_load(silent: true));
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final selections = await _repo.listTopicSelectionsForChat(widget.chatId,
          cacheFirst: false);
      final found =
          selections.where((s) => s.id == widget.selection.id).toList();
      final options =
          await _repo.listTopicOptionsForSelection(widget.selection.id);
      if (!mounted) return;
      setState(() {
        _selection = found.isNotEmpty ? found.first : widget.selection;
        _options = options;
        _lastGoodOptions = options;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_lastGoodOptions.isEmpty) {
          _error = 'Не удалось загрузить темы';
        } else {
          _options = _lastGoodOptions;
          _error = 'Офлайн: показаны последние данные';
        }
      });
    }
  }

  ChatTopicOption? get _myPickOption {
    for (final o in _options) {
      if (o.myPick) return o;
    }
    return null;
  }

  List<ChatTopicOption> get _filtered {
    final q = _query.trim().toLowerCase();
    return _options.where((o) {
      switch (_filter) {
        case _TopicFilter.free:
          if (o.isFull && !o.myPick) return false;
        case _TopicFilter.taken:
          if (!o.isFull && !o.myPick) return false;
        case _TopicFilter.all:
          break;
      }
      if (q.isEmpty) return true;
      return o.title.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  int get _freeCount =>
      _options.where((o) => !o.isFull || o.myPick).length;
  int get _takenCount => _options.where((o) => o.isFull && !o.myPick).length;

  String _friendlyPickError(Object e) {
    final msg = e.toString();
    if (msg.contains('option_full')) {
      return 'Эту тему уже выбрали';
    }
    if (msg.contains('selection_unavailable')) {
      return 'Выбор темы недоступен (закрыт или истёк срок)';
    }
    if (msg.contains('pick_change_forbidden')) {
      return 'Смена темы запрещена';
    }
    return 'Не удалось выбрать тему';
  }

  Future<void> _pick(ChatTopicOption option) async {
    if (_acting) return;
    KeyboardDismissScope.unfocus(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подтвердить выбор'),
        content: Text('Выбрать тему «${option.title}»?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выбрать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _acting = true;
      _raceMessage = null;
    });
    try {
      await _repo.pickTopic(
        selectionId: widget.selection.id,
        optionId: option.id,
      );
      HapticFeedback.lightImpact();
      await _load(silent: true);
      if (!mounted) return;
      setState(() => _raceMessage = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Тема «${option.title}» выбрана')),
      );
      // Keep chooser open so the user sees updated free/taken state.
    } catch (e) {
      if (!mounted) return;
      final message = _friendlyPickError(e);
      setState(() => _raceMessage = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      await _load(silent: true);
      // Race conflict: sheet stays open with the conflict message.
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _cancelMyPick() async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await _repo.cancelTopicPick(widget.selection.id);
      await _load(silent: true);
      if (mounted) setState(() => _raceMessage = null);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось освободить тему')),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _releaseForUser(String userLabel, ChatTopicOption option) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Тема «${option.title}» занята ($userLabel). '
          'Освобождение — через переназначение организатором.',
        ),
      ),
    );
  }

  Future<void> _openSearchSheet() async {
    KeyboardDismissScope.unfocus(context);
    final initial = _searchCtrl.text;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TopicSearchSheet(initialQuery: initial),
    );
    if (!mounted || result == null) return;
    _searchCtrl.text = result;
    setState(() => _query = result);
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
    final selection = _selection ?? widget.selection;
    final myPick = _myPickOption;
    final filtered = _filtered;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final maxHeight = MediaQuery.sizeOf(context).height *
        (widget.asBottomSheet ? 0.92 : 1.0);

    final body = Column(
      children: [
        Expanded(
          child: KeyboardDismissScope(
            child: CustomScrollView(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      widget.asBottomSheet ? 10 : 12,
                      20,
                      8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.asBottomSheet)
                          Center(
                            child: Container(
                              width: 42,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 14),
                              decoration: BoxDecoration(
                                color: cs.outlineVariant,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          )
                        else
                          Align(
                            alignment: Alignment.centerLeft,
                            child: IconButton(
                              tooltip: 'Назад',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ),
                        _ChooserHero(
                          title: selection.title,
                          deadlineLabel: selection.deadlineAt == null
                              ? null
                              : 'Выбрать до ${_fmt(selection.deadlineAt!)}',
                          freeSlots: selection.freeSlots,
                          totalCapacity: selection.totalCapacity,
                        ),
                        if (myPick != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: cs.primary.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.check_circle_rounded,
                                    color: cs.primary, size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Ваша тема: ${myPick.title}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (_raceMessage != null) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEBEE),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFE53935)
                                    .withValues(alpha: 0.35),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline_rounded,
                                    color: Color(0xFFE53935), size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _raceMessage!,
                                    style:
                                        theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFFB71C1C),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Скрыть',
                                  onPressed: () =>
                                      setState(() => _raceMessage = null),
                                  icon: const Icon(Icons.close_rounded,
                                      size: 18),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.error),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Material(
                          color: const Color(0xFFF6F7FB),
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            onTap: _openSearchSheet,
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFFE1E5EF),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.search_rounded,
                                      color: cs.primary),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _query.trim().isEmpty
                                          ? 'Поиск темы'
                                          : _query.trim(),
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color: _query.trim().isEmpty
                                            ? Colors.black45
                                            : Colors.black87,
                                        fontWeight: _query.trim().isEmpty
                                            ? FontWeight.w500
                                            : FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (_query.trim().isNotEmpty)
                                    IconButton(
                                      tooltip: 'Очистить',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _query = '');
                                      },
                                      icon: const Icon(Icons.close_rounded,
                                          size: 18),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _FilterChip(
                              label: 'Свободные',
                              count: _freeCount,
                              selected: _filter == _TopicFilter.free,
                              onTap: () =>
                                  setState(() => _filter = _TopicFilter.free),
                            ),
                            _FilterChip(
                              label: 'Занятые',
                              count: _takenCount,
                              selected: _filter == _TopicFilter.taken,
                              onTap: () =>
                                  setState(() => _filter = _TopicFilter.taken),
                            ),
                            _FilterChip(
                              label: 'Все',
                              count: _options.length,
                              selected: _filter == _TopicFilter.all,
                              onTap: () =>
                                  setState(() => _filter = _TopicFilter.all),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                if (_loading && _options.isEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (_, __) => const _TopicSkeleton(),
                        childCount: 6,
                      ),
                    ),
                  )
                else if (filtered.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _filter == _TopicFilter.free
                              ? 'Свободных тем нет'
                              : _filter == _TopicFilter.taken
                                  ? 'Занятых тем нет'
                                  : 'Темы не найдены',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final o = filtered[index];
                          final selected = myPick?.id == o.id;
                          final names = o.pickerNames;
                          final taken = o.isFull && !selected;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Material(
                              color: selected
                                  ? cs.primary.withValues(alpha: 0.10)
                                  : const Color(0xFFF6F7FB),
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: !selection.isOpen ||
                                        _acting ||
                                        taken
                                    ? null
                                    : () => _pick(o),
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: selected
                                          ? cs.primary.withValues(alpha: 0.35)
                                          : const Color(0xFFE1E5EF),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              o.title,
                                              style: theme
                                                  .textTheme.titleSmall
                                                  ?.copyWith(
                                                fontWeight: FontWeight.w800,
                                                color: taken
                                                    ? Colors.black38
                                                    : Colors.black87,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              taken
                                                  ? 'Занято'
                                                  : 'Свободно ${o.freeSlots} из ${o.capacity}',
                                              style: theme
                                                  .textTheme.bodySmall
                                                  ?.copyWith(
                                                color: taken
                                                    ? const Color(0xFFE53935)
                                                        .withValues(alpha: 0.85)
                                                    : Colors.black54,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            if (names.isNotEmpty &&
                                                selection
                                                    .showResultsToAll) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                names.join(', '),
                                                style: theme
                                                    .textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: Colors.black45,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      if (selected)
                                        Icon(Icons.check_circle,
                                            color: cs.primary)
                                      else if (taken)
                                        Icon(
                                          Icons.lock_outline,
                                          color: Colors.black
                                              .withValues(alpha: 0.30),
                                        )
                                      else
                                        Icon(
                                          Icons.chevron_right,
                                          color: Colors.black
                                              .withValues(alpha: 0.40),
                                        ),
                                      if (widget.canManage &&
                                          names.isNotEmpty &&
                                          o.isFull)
                                        IconButton(
                                          tooltip: 'Действия организатора',
                                          onPressed: () => _releaseForUser(
                                              names.first, o),
                                          icon: const Icon(
                                              Icons.manage_accounts),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        childCount: filtered.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (myPick != null && selection.isOpen && selection.allowChange)
          Container(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + viewInsets.bottom),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                top: BorderSide(
                  color: Colors.black.withValues(alpha: 0.06),
                ),
              ),
            ),
            child: OutlinedButton(
              onPressed: _acting ? null : _cancelMyPick,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('Освободить / изменить выбор'),
            ),
          )
        else
          SizedBox(height: viewInsets.bottom),
      ],
    );

    if (widget.asBottomSheet) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
          child: SizedBox(
            height: maxHeight,
            child: Material(
              color: cs.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(top: false, child: body),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: body,
        ),
      ),
    );
  }
}

class _TopicSearchSheet extends StatefulWidget {
  const _TopicSearchSheet({required this.initialQuery});

  final String initialQuery;

  @override
  State<_TopicSearchSheet> createState() => _TopicSearchSheetState();
}

class _TopicSearchSheetState extends State<_TopicSearchSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
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
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => Navigator.pop(context, v.trim()),
                  decoration: InputDecoration(
                    labelText: 'Поиск темы',
                    hintText: 'Начните вводить название',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _ctrl.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _ctrl.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
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
                      borderSide:
                          const BorderSide(color: Colors.black87, width: 1.4),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, _ctrl.text.trim()),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Найти',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChooserHero extends StatelessWidget {
  const _ChooserHero({
    required this.title,
    required this.deadlineLabel,
    required this.freeSlots,
    required this.totalCapacity,
  });

  final String title;
  final String? deadlineLabel;
  final int freeSlots;
  final int totalCapacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        children: [
          Container(
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
          ),
          Positioned(
            right: -24,
            top: -28,
            child: ClipOval(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  width: 110,
                  height: 110,
                  color: cs.primary.withValues(alpha: 0.16),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
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
                  child: Icon(Icons.topic_outlined, color: cs.primary, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        deadlineLabel ??
                            (totalCapacity > 0
                                ? 'Свободно $freeSlots из $totalCapacity'
                                : 'Список тем'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.black.withValues(alpha: 0.62),
                          height: 1.25,
                        ),
                      ),
                      if (deadlineLabel != null && totalCapacity > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Свободно $freeSlots из $totalCapacity',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.black45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = selected ? cs.primary : const Color(0xFFF6F7FB);
    final fg = selected ? cs.onPrimary : Colors.black87;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? Colors.transparent : const Color(0xFFE1E5EF),
            ),
          ),
          child: Text(
            '$label · $count',
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

class _TopicSkeleton extends StatelessWidget {
  const _TopicSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E5EF)),
      ),
    );
  }
}
