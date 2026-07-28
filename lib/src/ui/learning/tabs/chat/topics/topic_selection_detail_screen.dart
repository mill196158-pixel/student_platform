import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/chat_group_actions_repository.dart';
import '../models/chat_group_actions.dart';

/// Modern topic chooser opened from the compact chat bubble.
class TopicSelectionDetailScreen extends StatefulWidget {
  const TopicSelectionDetailScreen({
    super.key,
    required this.chatId,
    required this.selection,
    this.repository,
    this.canManage = false,
  });

  final String chatId;
  final ChatTopicSelection selection;
  final ChatGroupActionsRepository? repository;
  final bool canManage;

  @override
  State<TopicSelectionDetailScreen> createState() =>
      _TopicSelectionDetailScreenState();
}

class _TopicSelectionDetailScreenState
    extends State<TopicSelectionDetailScreen> {
  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository();

  ChatTopicSelection? _selection;
  List<ChatTopicOption> _options = const [];
  List<ChatTopicOption> _lastGoodOptions = const [];
  bool _loading = true;
  String? _error;
  bool _acting = false;
  bool _freeOnly = true;
  String _query = '';
  RealtimeChannel? _channel;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _selection = widget.selection;
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
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
      if (_freeOnly && o.isFull && !o.myPick) return false;
      if (q.isEmpty) return true;
      return o.title.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  String _friendlyPickError(Object e) {
    final msg = e.toString();
    if (msg.contains('option_full')) {
      return 'Эту тему только что заняли. Выберите другую.';
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

    setState(() => _acting = true);
    try {
      await _repo.pickTopic(
        selectionId: widget.selection.id,
        optionId: option.id,
      );
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyPickError(e))),
      );
      await _load(silent: true);
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
    // Organizer release uses reassign/release RPCs when user id is known.
    // pickerNames are display-only; show guidance for now if ids unavailable.
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

    return Scaffold(
      appBar: AppBar(title: Text(selection.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (selection.deadlineAt != null)
                  Text(
                    'Выбрать до ${_fmt(selection.deadlineAt!)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  selection.totalCapacity > 0
                      ? 'Свободно ${selection.freeSlots} из ${selection.totalCapacity}'
                      : 'Список тем',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                if (myPick != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Ваша тема: ${myPick.title}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Поиск темы',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Свободные')),
                    ButtonSegment(value: false, label: Text('Все')),
                  ],
                  selected: {_freeOnly},
                  onSelectionChanged: (s) =>
                      setState(() => _freeOnly = s.first),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading && _options.isEmpty
                ? ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: 6,
                    itemBuilder: (_, __) => const _TopicSkeleton(),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: filtered.length +
                          ((myPick != null &&
                                  selection.isOpen &&
                                  selection.allowChange)
                              ? 1
                              : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        if (index >= filtered.length) {
                          return OutlinedButton(
                            onPressed: _acting ? null : _cancelMyPick,
                            child: const Text('Освободить / изменить выбор'),
                          );
                        }
                        final o = filtered[index];
                        final selected = myPick?.id == o.id;
                        final names = o.pickerNames;
                        return Material(
                          color: selected
                              ? cs.primaryContainer.withValues(alpha: 0.55)
                              : cs.surfaceContainerHighest
                                  .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: !selection.isOpen ||
                                    _acting ||
                                    (o.isFull && !selected)
                                ? null
                                : () => _pick(o),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          o.title,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            color: o.isFull && !selected
                                                ? cs.onSurface
                                                    .withValues(alpha: 0.45)
                                                : cs.onSurface,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          o.isFull && !selected
                                              ? 'Занято'
                                              : 'Свободно ${o.freeSlots} из ${o.capacity}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: cs.onSurface
                                                .withValues(alpha: 0.6),
                                          ),
                                        ),
                                        if (names.isNotEmpty &&
                                            selection.showResultsToAll) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            names.join(', '),
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: cs.onSurface
                                                  .withValues(alpha: 0.55),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (selected)
                                    Icon(Icons.check_circle, color: cs.primary)
                                  else if (o.isFull)
                                    Icon(Icons.lock_outline,
                                        color: cs.onSurface
                                            .withValues(alpha: 0.35))
                                  else
                                    Icon(Icons.chevron_right,
                                        color: cs.onSurface
                                            .withValues(alpha: 0.45)),
                                  if (widget.canManage &&
                                      names.isNotEmpty &&
                                      o.isFull)
                                    IconButton(
                                      tooltip: 'Действия организатора',
                                      onPressed: () =>
                                          _releaseForUser(names.first, o),
                                      icon: const Icon(Icons.manage_accounts),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
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
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}
