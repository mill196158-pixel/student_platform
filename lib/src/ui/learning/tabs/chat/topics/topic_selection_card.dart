import 'package:flutter/material.dart';

import '../../../models/message.dart';
import '../data/chat_group_actions_repository.dart';
import '../models/chat_group_actions.dart';
import 'topic_selection_detail_screen.dart';

/// In-chat card for `content.card = topic_selection`.
class TopicSelectionCard extends StatefulWidget {
  const TopicSelectionCard({
    super.key,
    required this.message,
    this.onLongPress,
    this.boundaryKey,
    this.repository,
    this.onOpenChat,
  });

  final Message message;
  final VoidCallback? onLongPress;
  final Key? boundaryKey;
  final ChatGroupActionsRepository? repository;
  final VoidCallback? onOpenChat;

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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicSelectionDetailScreen(
          chatId: chatId,
          selection: _selection!,
          repository: repo,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = _selection?.title ??
        widget.message.text.replaceFirst(RegExp(r'^Выбор темы:\s*'), '');
    final subtitle = _loading
        ? 'Загрузка…'
        : (_selection == null
            ? 'Нажмите, чтобы открыть выбор темы'
            : [
                if (_selection!.deadlineAt != null)
                  'Дедлайн: ${_fmt(_selection!.deadlineAt!)}',
                if (_selection!.totalCapacity > 0)
                  'Свободно ${_selection!.freeSlots} из ${_selection!.totalCapacity}',
                'Статус: ${_statusLabel(_selection!.status)}',
              ].join(' · '));

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
        child: Row(
          children: [
            Icon(Icons.format_list_numbered_rtl, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Выбор темы',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.primary,
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
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.black45),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}. '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'open':
        return 'открыт';
      case 'closed':
        return 'закрыт';
      case 'cancelled':
        return 'отменён';
      default:
        return status;
    }
  }
}

/// In-chat card for `content.card = collection`.
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
    final title = message.text.replaceFirst(RegExp(r'^Сбор:\s*'), '').trim();

    return GestureDetector(
      key: boundaryKey,
      onLongPress: onLongPress,
      onTap: onOpenChat,
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
                    'Сбор группы',
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
                    'Приложение не принимает платежи — переводы вне приложения.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.black45),
          ],
        ),
      ),
    );
  }
}
