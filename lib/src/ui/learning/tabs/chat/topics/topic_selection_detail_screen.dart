import 'package:flutter/material.dart';

import '../data/chat_group_actions_repository.dart';
import '../models/chat_group_actions.dart';

/// Detail screen for an in-chat topic selection card.
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
  bool _loading = true;
  String? _error;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _selection = widget.selection;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить темы';
      });
    }
  }

  ChatTopicOption? get _myPickOption {
    for (final o in _options) {
      if (o.myPick) return o;
    }
    return null;
  }

  String _friendlyPickError(Object e) {
    final msg = e.toString();
    if (msg.contains('option_full')) {
      return 'Мест больше нет';
    }
    if (msg.contains('selection_unavailable')) {
      return 'Выбор темы недоступен (закрыт или истёк дедлайн)';
    }
    if (msg.contains('pick_change_forbidden')) {
      return 'Смена темы запрещена';
    }
    return 'Не удалось выбрать тему';
  }

  Future<void> _pick(ChatTopicOption option) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await _repo.pickTopic(
        selectionId: widget.selection.id,
        optionId: option.id,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyPickError(e))),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _cancelMyPick() async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await _repo.cancelTopicPick(widget.selection.id);
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отменить выбор')),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
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
    final selection = _selection ?? widget.selection;
    final myPick = _myPickOption;

    return Scaffold(
      appBar: AppBar(title: Text(selection.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  if (selection.description.trim().isNotEmpty)
                    Text(selection.description),
                  if (selection.deadlineAt != null) ...[
                    const SizedBox(height: 8),
                    Text('Дедлайн выбора: ${_fmt(selection.deadlineAt!)}'),
                  ],
                  if (selection.completionDeadlineAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Срок выполнения: ${_fmt(selection.completionDeadlineAt!)}',
                    ),
                  ],
                  if (selection.totalCapacity > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Свободно ${selection.freeSlots} из ${selection.totalCapacity}',
                    ),
                  ],
                  if (selection.sourceFileId != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Исходный документ прикреплён',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.black54,
                          ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Темы',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ..._options.map((o) {
                    final names = o.pickerNames;
                    final subtitleParts = <String>[
                      'Свободно: ${o.freeSlots} из ${o.capacity}',
                      if (names.isNotEmpty) names.join(', '),
                    ];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(o.title),
                      subtitle: Text(subtitleParts.join(' · ')),
                      trailing: myPick?.id == o.id
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : TextButton(
                              onPressed:
                                  selection.isOpen && !o.isFull && !_acting
                                      ? () => _pick(o)
                                      : null,
                              child: const Text('Выбрать'),
                            ),
                    );
                  }),
                  if (myPick != null &&
                      selection.isOpen &&
                      selection.allowChange)
                    TextButton(
                      onPressed: _acting ? null : _cancelMyPick,
                      child: const Text('Отменить выбор'),
                    ),
                  if (widget.canManage && selection.isOpen)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Действия организатора (переназначение) — в следующей версии.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.black54,
                            ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
