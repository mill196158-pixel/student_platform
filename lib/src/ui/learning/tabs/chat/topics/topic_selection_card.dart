import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
    final cta = closed
        ? 'Смотреть'
        : (_selection?.allowChange == true ? 'Изменить выбор' : 'Выбрать тему');

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
                    child: Text(cta),
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
class CollectionCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title =
        message.text.replaceFirst(RegExp(r'^(Сбор|Скинуться):\s*'), '').trim();

    return GestureDetector(
      key: boundaryKey,
      onLongPress: onLongPress,
      onTap: () {
        if (onOpenChat != null) {
          onOpenChat!();
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const GroupSpaceScreen()),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.secondaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.secondary.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.volunteer_activism_outlined, color: cs.secondary),
            const SizedBox(width: 10),
            Expanded(
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
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Переводы вне приложения. Нажмите, чтобы отметить.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: cs.onSurface.withValues(alpha: 0.45)),
          ],
        ),
      ),
    );
  }
}
