// =============================
// FILE: lib/src/ui/learning/tabs/chat/topics/topic_selection_card.dart
// =============================
//
// Stage 13.12 — chat bubble previews for `topic_selection` / `collection`
// cards, redesigned to read from the shared [ChatActionCardsCache] batch
// cache (see chat/data/chat_action_cards_cache.dart) instead of each card
// independently calling a chat-wide "list all selections/collections" RPC.
// Tapping either card now opens [UnifiedTaskDetailsScreen] — the single
// task-action destination — instead of the old chat-scoped chooser sheet
// (topic) or [GroupSpaceScreen] (collection, which leaked peer proofs /
// comments to participants).
import 'package:flutter/material.dart';

import '../../../models/message.dart';
import '../data/chat_action_cards_cache.dart';
import '../data/chat_composer_capabilities_repository.dart';
import '../data/chat_group_actions_repository.dart';
import '../unified_task_details_screen.dart';

String _fmtDate(DateTime dt) {
  return '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

bool _looksLikeUuid(String value) {
  final v = value.trim();
  if (v.isEmpty) return false;
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(v);
}

/// Compact in-chat preview for `content.card = topic_selection`.
class TopicSelectionCard extends StatefulWidget {
  const TopicSelectionCard({
    super.key,
    required this.message,
    this.onLongPress,
    this.boundaryKey,
    this.repository,
    this.capabilitiesRepository,
    this.cache,
    this.onOpenChat,
    this.canManage,
    this.canDelete,
    this.canEditOwnBeforeActivity,
  });

  final Message message;
  final VoidCallback? onLongPress;
  final Key? boundaryKey;
  final ChatGroupActionsRepository? repository;
  final ChatComposerCapabilitiesRepository? capabilitiesRepository;
  final ChatActionCardsCache? cache;
  final VoidCallback? onOpenChat;

  /// Server SoT: `can_moderate_topic_selection`. Never inferred from TeamCubit.
  final bool? canManage;
  final bool? canDelete;
  final bool? canEditOwnBeforeActivity;

  @override
  State<TopicSelectionCard> createState() => _TopicSelectionCardState();
}

class _TopicSelectionCardState extends State<TopicSelectionCard> {
  ChatActionCardEntry? _entry;
  bool _loading = true;

  ChatActionCardsCache get _cache =>
      widget.cache ?? ChatActionCardsCache.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TopicSelectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.cardEntityId != widget.message.cardEntityId ||
        oldWidget.message.chatId != widget.message.chatId) {
      _load();
    }
  }

  Future<void> _load() async {
    final selectionId = widget.message.cardEntityId;
    final chatId = widget.message.chatId;
    if (selectionId == null || selectionId.isEmpty || chatId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // Synchronous pre-fill from the in-memory cache. Assigned directly
    // (no setState) since this always runs before the first build — either
    // during initState's synchronous prelude or synchronously at the top of
    // this async function on subsequent calls.
    final cached = _cache.peek(ChatActionCardKind.topicSelection, selectionId);
    if (cached != null) {
      _entry = cached;
      _loading = false;
    }

    try {
      final entry = await _cache.ensureLoaded(
        chatId,
        kind: ChatActionCardKind.topicSelection,
        entityId: selectionId,
        cardMessageId:
            _looksLikeUuid(widget.message.id) ? widget.message.id : null,
      );
      if (!mounted) return;
      setState(() {
        _entry = entry ?? _entry;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openDetail() async {
    final selectionId = widget.message.cardEntityId;
    final chatId = widget.message.chatId;
    if (selectionId == null || selectionId.isEmpty || chatId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть выбор темы')),
      );
      return;
    }
    await openUnifiedTaskDetails(
      context,
      kind: ChatActionCardKind.topicSelection,
      entityId: selectionId,
      chatId: chatId,
      cardMessageId: _entry?.cardMessageId ??
          (_looksLikeUuid(widget.message.id) ? widget.message.id : null),
      title: _entry?.title,
      repository: widget.repository,
      cache: _cache,
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entry = _entry;
    final fallbackTitle =
        widget.message.text.replaceFirst(RegExp(r'^Выбор темы:\s*'), '');
    final title =
        (entry?.title.isNotEmpty ?? false) ? entry!.title : fallbackTitle;
    final unavailable = entry != null && !entry.available;
    final closed = entry != null && entry.available && entry.isClosed;
    final progress = (entry != null && entry.totalCapacity > 0)
        ? 'Выбрано ${entry.takenSlots} из ${entry.totalCapacity}'
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
        child: _loading && entry == null
            ? const _CardSkeleton()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CardBadge(label: 'Выбор темы', color: cs.primary),
                  const SizedBox(height: 6),
                  Text(
                    title.isNotEmpty ? title : 'Без названия',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                  if ((entry?.description ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry!.description.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (unavailable) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Недоступно',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else if (closed) ...[
                    const SizedBox(height: 10),
                    _ClosedCompactRow(title: title),
                  ] else ...[
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (entry?.deadlineAt != null)
                          'До ${_fmtDate(entry!.deadlineAt!)}',
                        if (progress != null) progress,
                        if (entry?.myPickText != null)
                          'Моя тема: ${entry!.myPickText}',
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
                        FilledButton.tonal(
                          onPressed: _openDetail,
                          child: Text(
                            (entry?.myPickText != null)
                                ? 'Изменить выбор'
                                : 'Выбрать тему',
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
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
    this.repository,
    this.capabilitiesRepository,
    this.cache,
    this.canManage,
    this.canDelete,
  });

  final Message message;
  final VoidCallback? onLongPress;
  final Key? boundaryKey;
  final VoidCallback? onOpenChat;
  final ChatGroupActionsRepository? repository;
  final ChatComposerCapabilitiesRepository? capabilitiesRepository;
  final ChatActionCardsCache? cache;
  final bool? canManage;
  final bool? canDelete;

  @override
  State<CollectionCard> createState() => _CollectionCardState();
}

class _CollectionCardState extends State<CollectionCard> {
  ChatActionCardEntry? _entry;
  bool _loading = true;
  bool _reporting = false;
  bool _canManage = false;
  bool _canDelete = false;

  ChatActionCardsCache get _cache =>
      widget.cache ?? ChatActionCardsCache.instance;

  @override
  void initState() {
    super.initState();
    _canManage = widget.canManage ?? false;
    _canDelete = widget.canDelete ?? false;
    _load();
    _resolveCapabilities();
  }

  @override
  void didUpdateWidget(covariant CollectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.canManage != widget.canManage ||
        oldWidget.canDelete != widget.canDelete) {
      _canManage = widget.canManage ?? _canManage;
      _canDelete = widget.canDelete ?? _canDelete;
    }
    if (oldWidget.message.cardEntityId != widget.message.cardEntityId ||
        oldWidget.message.chatId != widget.message.chatId) {
      _load();
    }
  }

  Future<void> _resolveCapabilities() async {
    if (widget.canManage != null && widget.canDelete != null) {
      if (!mounted) return;
      setState(() {
        _canManage = widget.canManage!;
        _canDelete = widget.canDelete!;
      });
      return;
    }
    final chatId = widget.message.chatId;
    if (chatId.isEmpty) return;
    try {
      final caps = await (widget.capabilitiesRepository ??
              ChatComposerCapabilitiesRepository())
          .load(chatId);
      if (!mounted) return;
      setState(() {
        _canManage = widget.canManage ?? caps.canModerateCollection;
        _canDelete = widget.canDelete ?? caps.canDeleteGroupAction;
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    final id = widget.message.cardEntityId;
    final chatId = widget.message.chatId;
    if (id == null || id.isEmpty || chatId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final cached = _cache.peek(ChatActionCardKind.groupCollection, id);
    if (cached != null) {
      _entry = cached;
      _loading = false;
    }

    try {
      final entry = await _cache.ensureLoaded(
        chatId,
        kind: ChatActionCardKind.groupCollection,
        entityId: id,
        cardMessageId:
            _looksLikeUuid(widget.message.id) ? widget.message.id : null,
      );
      if (!mounted) return;
      setState(() {
        _entry = entry ?? _entry;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    final id = widget.message.cardEntityId;
    final chatId = widget.message.chatId;
    if (id == null || id.isEmpty || chatId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть сбор')),
      );
      return;
    }
    await openUnifiedTaskDetails(
      context,
      kind: ChatActionCardKind.groupCollection,
      entityId: id,
      chatId: chatId,
      cardMessageId: _entry?.cardMessageId ??
          (_looksLikeUuid(widget.message.id) ? widget.message.id : null),
      title: _entry?.title,
      repository: widget.repository,
      cache: _cache,
    );
    if (mounted) await _load();
  }

  Future<void> _markTransferred() async {
    final id = widget.message.cardEntityId;
    if (id == null || id.isEmpty || _reporting) return;
    setState(() => _reporting = true);
    try {
      await (widget.repository ?? ChatGroupActionsRepository())
          .createCollectionContributionReport(id);
      if (!mounted) return;
      _cache.invalidate(ChatActionCardKind.groupCollection, id);
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

  Future<void> _deleteCollection() async {
    final id = widget.message.cardEntityId;
    if (id == null || id.isEmpty || !_canDelete) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сбор?'),
        content: const Text('Сбор будет отменён для всех участников.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final repo = widget.repository ?? ChatGroupActionsRepository();
      await repo.deleteGroupAction(kind: 'collection', entityId: id);
      _cache.markTombstone(ChatActionCardKind.groupCollection, id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сбор удалён')),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить сбор')),
      );
    }
  }

  bool _canShowDelete(bool closed) {
    if (!_canDelete || closed) return false;
    if (_canManage) return true;
    final entry = _entry;
    if (entry == null) return true;
    final hasActivity = entry.takenSlots > 0 ||
        (entry.myStatus != null &&
            entry.myStatus != 'none' &&
            entry.myStatus!.isNotEmpty) ||
        (entry.organizerStats != null &&
            ((entry.organizerStats!['confirmed'] as num?) ?? 0) > 0);
    return !hasActivity;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entry = _entry;
    final fallbackTitle = widget.message.text
        .replaceFirst(RegExp(r'^(Сбор|Скинуться):\s*'), '')
        .trim();
    final title =
        (entry?.title.isNotEmpty ?? false) ? entry!.title : fallbackTitle;
    final unavailable = entry != null && !entry.available;
    final closed = entry != null && entry.available && entry.isClosed;

    String myStatusLabel() {
      final status = entry?.myStatus ?? 'none';
      switch (status) {
        case 'confirmed':
          return 'Подтверждено';
        case 'not_received':
          return 'Не поступило';
        case 'needs_clarification':
          return 'Уточнить';
        case 'reported':
        case 'pending_review':
          return 'Перевёл — на проверке';
        default:
          return 'Ожидает';
      }
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
        child: _loading && entry == null
            ? const _CardSkeleton()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CardBadge(label: 'Скинуться', color: cs.secondary),
                  const SizedBox(height: 4),
                  Text(
                    title.isNotEmpty ? title : 'Без названия',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                  if ((entry?.purpose ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry!.purpose.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (unavailable) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Недоступно',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else if (closed) ...[
                    const SizedBox(height: 10),
                    _ClosedCompactRow(title: title),
                  ] else ...[
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (entry?.deadlineAt != null)
                          'До ${_fmtDate(entry!.deadlineAt!)}',
                        'Мой статус: ${myStatusLabel()}',
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
                        FilledButton.tonal(
                          onPressed: _reporting ? null : _markTransferred,
                          child: _reporting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Я перевёл'),
                        ),
                        TextButton(
                          onPressed: _open,
                          child: const Text('Подробнее'),
                        ),
                        if (_canShowDelete(closed))
                          TextButton(
                            onPressed: _deleteCollection,
                            child: Text(
                              'Удалить',
                              style: TextStyle(color: cs.error),
                            ),
                          ),
                        if (_canManage)
                          Text(
                            'Орг.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.secondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _CardBadge extends StatelessWidget {
  const _CardBadge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11.5,
        ),
      ),
    );
  }
}

class _ClosedCompactRow extends StatelessWidget {
  const _ClosedCompactRow({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Icon(Icons.task_alt_rounded, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Задание завершено',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget bar(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar(72, 14),
        const SizedBox(height: 8),
        bar(160, 16),
        const SizedBox(height: 8),
        bar(120, 12),
      ],
    );
  }
}
