import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../models/message.dart';
import '../../../state/team_cubit.dart';
import '../../../../group_space/group_space_screen.dart';
import '../data/chat_group_actions_repository.dart';
import '../models/chat_group_actions.dart';
import 'topic_selection_detail_screen.dart';

/// Compact in-chat preview for `content.card = topic_selection`.
class TopicSelectionCard extends StatefulWidget {
  const TopicSelectionCard({
    super.key,
    required this.message,
    this.onLongPress,
    this.boundaryKey,
    this.repository,
    this.onOpenChat,
    this.canManage,
  });

  final Message message;
  final VoidCallback? onLongPress;
  final Key? boundaryKey;
  final ChatGroupActionsRepository? repository;
  final VoidCallback? onOpenChat;
  final bool? canManage;

  @override
  State<TopicSelectionCard> createState() => _TopicSelectionCardState();
}

class _TopicSelectionCardState extends State<TopicSelectionCard> {
  ChatTopicSelection? _selection;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final selectionId = widget.message.cardEntityId;
    if (selectionId == null || selectionId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final repo = widget.repository ?? ChatGroupActionsRepository();
    try {
      final chatId = widget.message.chatId;
      final list = chatId.isNotEmpty
          ? await repo.listTopicSelectionsForChat(chatId, cacheFirst: true)
          : const <ChatTopicSelection>[];
      final found = list.where((e) => e.id == selectionId).toList();
      if (!mounted) return;
      setState(() {
        _selection = found.isNotEmpty ? found.first : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openDetail() async {
    if (_selection == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть выбор темы')),
      );
      return;
    }
    final chatId = widget.message.chatId;
    if (chatId.isEmpty) return;
    final repo = widget.repository ?? ChatGroupActionsRepository();
    var canManage = widget.canManage;
    if (canManage == null) {
      try {
        canManage = context.read<TeamCubit>().state.isStarosta;
      } catch (_) {
        canManage = false;
      }
    }
    await showTopicSelectionChooser(
      context,
      chatId: chatId,
      selection: _selection!,
      repository: repo,
      canManage: canManage,
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = _selection?.title ??
        widget.message.text.replaceFirst(RegExp(r'^Выбор темы:\s*'), '');
    final closed = _selection != null && !_selection!.isOpen;
    final progress = (_selection != null && _selection!.totalCapacity > 0)
        ? 'Выбрано ${_selection!.takenSlots} из ${_selection!.totalCapacity}'
        : null;

    return GestureDetector(
      key: widget.boundaryKey,
      onLongPress: widget.onLongPress,
      onTap: _openDetail,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title.isNotEmpty ? title : 'Без названия',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (_selection?.deadlineAt != null)
                  'До ${_fmt(_selection!.deadlineAt!)}',
                if (progress != null) progress,
                if (closed) 'Закрыто',
                if (_loading) '…',
              ].where((e) => e.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                if (!closed)
                  FilledButton.tonal(
                    onPressed: _openDetail,
                    child: const Text('Выбрать тему'),
                  ),
                if (!closed && _selection?.allowChange == true)
                  TextButton(
                    onPressed: _openDetail,
                    child: const Text('Изменить выбор'),
                  ),
                if (closed)
                  FilledButton.tonal(
                    onPressed: _openDetail,
                    child: const Text('Смотреть'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// In-chat card for `content.card = collection` («Скинуться»).
class CollectionCard extends StatefulWidget {
  const CollectionCard({
    super.key,
    required this.message,
    this.onLongPress,
    this.boundaryKey,
    this.onOpenChat,
  });

  final Message message;
  final VoidCallback? onLongPress;
  final Key? boundaryKey;
  final VoidCallback? onOpenChat;

  @override
  State<CollectionCard> createState() => _CollectionCardState();
}

class _CollectionCardState extends State<CollectionCard> {
  Map<String, dynamic>? _collection;
  bool _loading = true;
  bool _reporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.message.cardEntityId;
    if (id == null || id.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final res = await Supabase.instance.client.rpc('list_group_collections');
      Map<String, dynamic>? found;
      if (res is List) {
        for (final row in res) {
          if (row is Map && row['id']?.toString() == id) {
            found = Map<String, dynamic>.from(row);
            break;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _collection = found;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    if (widget.onOpenChat != null) {
      widget.onOpenChat!();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GroupSpaceScreen()),
    );
    if (mounted) await _load();
  }

  Future<void> _markTransferred() async {
    final id = widget.message.cardEntityId;
    if (id == null || id.isEmpty || _reporting) return;
    setState(() => _reporting = true);
    try {
      await Supabase.instance.client.rpc(
        'upsert_my_collection_contribution',
        params: {
          'p_collection_id': id,
          'p_participation_status': 'joining',
          'p_payment_status': 'reported',
          'p_comment': 'Я перевёл',
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отметили: «Я перевёл»')),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отметить перевод')),
      );
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fallbackTitle = widget.message.text
        .replaceFirst(RegExp(r'^(Сбор|Скинуться):\s*'), '')
        .trim();
    final title = (_collection?['title']?.toString() ?? fallbackTitle).trim();
    final purpose = (_collection?['purpose']?.toString() ?? '').trim();
    final status = (_collection?['status']?.toString() ?? 'open').trim();
    final closed = status != 'open';
    final deadlineRaw = _collection?['deadline_at']?.toString();
    final deadline = DateTime.tryParse(deadlineRaw ?? '');
    final reported =
        (_collection?['my_payment_status']?.toString() ?? '').trim();
    final organizerStatus = (_collection?['my_organizer_status']?.toString() ??
            _collection?['organizer_status']?.toString() ??
            '')
        .trim();
    final progressText = () {
      final done = int.tryParse(
            _collection?['confirmed_count']?.toString() ?? '',
          ) ??
          int.tryParse(_collection?['paid_count']?.toString() ?? '') ??
          0;
      final total = int.tryParse(
            _collection?['member_count']?.toString() ?? '',
          ) ??
          int.tryParse(_collection?['total_members']?.toString() ?? '') ??
          0;
      if (total > 0) return 'Прогресс $done из $total';
      return null;
    }();

    String myStatusLabel() {
      if (reported == 'confirmed' || organizerStatus == 'confirmed') {
        return 'Подтверждено';
      }
      if (reported == 'not_received' || organizerStatus == 'not_received') {
        return 'Не поступило';
      }
      if (reported == 'needs_clarification' ||
          organizerStatus == 'needs_clarification') {
        return 'Уточнить';
      }
      if (reported == 'reported' || reported == 'pending_review') {
        return 'Перевёл — на проверке';
      }
      return 'Ожидает';
    }

    return GestureDetector(
      key: widget.boundaryKey,
      onLongPress: widget.onLongPress,
      onTap: _open,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.secondaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.secondary.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Скинуться',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.secondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title.isNotEmpty ? title : 'Без названия',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
            if (purpose.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                purpose,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              [
                if (deadline != null) 'До ${_fmt(deadline)}',
                if (progressText != null) progressText,
                if (_loading) '…' else 'Мой статус: ${myStatusLabel()}',
                if (closed) 'Закрыто',
              ].where((e) => e.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (!closed)
                  FilledButton.tonal(
                    onPressed: _reporting ? null : _markTransferred,
                    child: _reporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Я перевёл'),
                  ),
                TextButton(
                  onPressed: _open,
                  child: Text(closed ? 'Смотреть' : 'Подробнее'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
