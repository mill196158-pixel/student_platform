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

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../data/personal_diary_service.dart';
import '../../../models/message.dart';
import '../../../state/team_cubit.dart';
import '../data/chat_action_cards_cache.dart';
import '../data/chat_composer_capabilities_repository.dart';
import '../data/chat_group_actions_repository.dart';
import '../models/group_action_labels.dart';
import '../navigation/group_action_deeplink.dart';

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
    final chatId = widget.message.chatId.trim();
    String? teamId;
    try {
      teamId = context.read<TeamCubit>().state.team.id;
    } catch (_) {}
    if (selectionId == null || selectionId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть список тем')),
      );
      return;
    }
    // Same path as schedule/home — root UnifiedTaskDetailsScreen.
    await openGroupActionDeeplink(
      context,
      GroupActionDeeplinkArgs(
        chatId: chatId.isEmpty ? null : chatId,
        teamId: teamId,
        cardMessageId: _entry?.cardMessageId ??
            (_looksLikeUuid(widget.message.id) ? widget.message.id : null),
        entityType: ChatActionCardKind.topicSelection,
        entityId: selectionId,
      ),
      // Already inside the team chat — do not push a second chat route.
      onOpenDiscussion: (_) {},
    );
    if (mounted) await _load();
  }

  Future<void> _deleteTopic() async {
    final id = widget.message.cardEntityId;
    if (id == null || id.isEmpty) return;
    if (!_canShowDelete(false)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить список тем?'),
        content: const Text('Список будет отменён для всех участников.'),
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
      await (widget.repository ?? ChatGroupActionsRepository())
          .deleteGroupAction(kind: 'topic_selection', entityId: id);
      _cache.markTombstone(ChatActionCardKind.topicSelection, id);
      await PersonalDiaryService.clearCachesAfterGroupActionDelete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Список тем удалён')),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось удалить. Возможно, уже есть выбранные темы.',
          ),
        ),
      );
    }
  }

  bool _canShowDelete(bool closed) {
    if (closed) return false;
    final entry = _entry;
    // Fail closed until hydrated; prefer batch `can_delete` (server SoT).
    if (entry == null) return false;
    if (entry.canDelete == true) return true;
    if (widget.canDelete != true) return false;
    return widget.canManage == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entry = _entry;
    final fallbackTitle = widget.message.text.replaceFirst(
      RegExp(r'^(Темы|Запись на тему|Выбор темы):\s*'),
      '',
    );
    final title =
        (entry?.title.isNotEmpty ?? false) ? entry!.title : fallbackTitle;
    final removed = entry != null &&
        (entry.tombstoned ||
            !entry.available ||
            entry.status == 'cancelled' ||
            entry.status == 'unavailable');
    if (removed) {
      return const SizedBox.shrink(key: ValueKey('topic_removed'));
    }
    final closed = entry != null && entry.available && entry.isClosed;
    final progress = (entry != null && entry.totalCapacity > 0)
        ? 'Занято ${entry.takenSlots} из ${entry.totalCapacity}'
        : null;

    final meta = [
      if (entry?.deadlineAt != null) 'До ${_fmtDate(entry!.deadlineAt!)}',
      if (progress != null) progress,
      if ((entry?.myPickText ?? '').trim().isNotEmpty)
        'Моя: ${entry!.myPickText}',
    ].where((e) => e.isNotEmpty).join(' · ');

    return GestureDetector(
      key: widget.boundaryKey,
      onLongPress: widget.onLongPress,
      onTap: _openDetail,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          // Match assignment bubble: soft primary wash, not loud primaryContainer.
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.primary.withValues(alpha: 0.28)),
        ),
        child: _loading && entry == null
            ? const _CardSkeleton()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        kTopicKindLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Открыть',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: cs.primary),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title.isNotEmpty ? title : 'Без названия',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                      height: 1.2,
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
                  if (closed) ...[
                    const SizedBox(height: 8),
                    _ClosedCompactRow(
                        title: title, label: kTopicClosedLabel),
                  ] else ...[
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (_canShowDelete(closed)) ...[
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _deleteTopic,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          'Удалить',
                          style: TextStyle(color: cs.error),
                        ),
                      ),
                    ],
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
    final chatId = widget.message.chatId.trim();
    String? teamId;
    try {
      teamId = context.read<TeamCubit>().state.team.id;
    } catch (_) {}
    if (id == null || id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть сбор')),
      );
      return;
    }
    // Same path as schedule/home — root UnifiedTaskDetailsScreen.
    await openGroupActionDeeplink(
      context,
      GroupActionDeeplinkArgs(
        chatId: chatId.isEmpty ? null : chatId,
        teamId: teamId,
        cardMessageId: _entry?.cardMessageId ??
            (_looksLikeUuid(widget.message.id) ? widget.message.id : null),
        entityType: ChatActionCardKind.groupCollection,
        entityId: id,
      ),
      // Already inside the team chat — do not push a second chat route.
      onOpenDiscussion: (_) {},
    );
    if (mounted) await _load();
  }

  Future<void> _deleteCollection() async {
    final id = widget.message.cardEntityId;
    if (id == null || id.isEmpty) return;
    if (!_canShowDelete(false)) return;
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
      await PersonalDiaryService.clearCachesAfterGroupActionDelete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сбор удалён')),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось удалить. Возможно, уже есть отметки участников.',
          ),
        ),
      );
    }
  }

  bool _canShowDelete(bool closed) {
    if (closed) return false;
    final entry = _entry;
    // Fail closed until hydrated; prefer batch `can_delete` (server SoT).
    if (entry == null) return false;
    if (entry.canDelete == true) return true;
    if (!_canDelete) return false;
    return _canManage;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entry = _entry;
    final fallbackTitle = widget.message.text
        .replaceFirst(RegExp(r'^(Сбор денег|Сбор|Скинуться):\s*'), '')
        .trim();
    final title =
        (entry?.title.isNotEmpty ?? false) ? entry!.title : fallbackTitle;
    final removed = entry != null &&
        (entry.tombstoned ||
            !entry.available ||
            entry.status == 'cancelled' ||
            entry.status == 'unavailable');
    if (removed) {
      return const SizedBox.shrink(key: ValueKey('collection_removed'));
    }
    final closed = entry != null && entry.available && entry.isClosed;

    final done = collectionParticipantIsDone(entry?.myStatus);
    final statusLine = collectionParticipantStatusLabel(entry?.myStatus);
    final meta = [
      if (entry?.deadlineAt != null) 'До ${_fmtDate(entry!.deadlineAt!)}',
      if (done) statusLine else 'Можно прикрепить чек',
    ].where((e) => e.isNotEmpty).join(' · ');

    return GestureDetector(
      key: widget.boundaryKey,
      onLongPress: widget.onLongPress,
      onTap: _open,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: cs.secondary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.secondary.withValues(alpha: 0.28)),
        ),
        child: _loading && entry == null
            ? const _CardSkeleton()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        kCollectionKindLabelLong,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (_canManage)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            'орг.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.secondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      Text(
                        'Открыть',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.secondary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: cs.secondary),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title.isNotEmpty ? title : 'Без названия',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                      height: 1.2,
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
                  if (closed) ...[
                    const SizedBox(height: 8),
                    _ClosedCompactRow(
                        title: title, label: kCollectionClosedLabel),
                  ] else ...[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: done
                            ? const Color(0xFF2F9D84)
                            : cs.onSurfaceVariant,
                        fontWeight: done ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (_canShowDelete(closed)) ...[
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _deleteCollection,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          'Удалить',
                          style: TextStyle(color: cs.error),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
      ),
    );
  }
}

class _ClosedCompactRow extends StatelessWidget {
  const _ClosedCompactRow({
    required this.title,
    this.label = 'Темы закрыты',
  });
  final String title;
  final String label;

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
            label,
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
