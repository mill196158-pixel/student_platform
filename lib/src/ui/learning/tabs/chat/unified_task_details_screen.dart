// =============================
// FILE: lib/src/ui/learning/tabs/chat/unified_task_details_screen.dart
// =============================
//
// Stage 13.12 — single destination for group-action ("card") details.
//
// Replaces the old pattern of tapping a topic/collection chat bubble and
// either opening a chat-scoped bottom sheet (topic) or the legacy
// GroupSpaceScreen (collection, which leaked peer proofs/comments to
// participants). Both kinds now open here via `get_task_details`, with a
// secondary "Открыть обсуждение" action to jump back into the chat thread.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../assignment_details_screen.dart';
import '../../state/team_cubit.dart';
import 'data/chat_action_cards_cache.dart';
import 'data/chat_group_actions_repository.dart';
import 'topics/topic_options_editor_screen.dart';

/// Opens [UnifiedTaskDetailsScreen] for the given card, falling back to a
/// friendly error if the chat/entity cannot be resolved.
Future<void> openUnifiedTaskDetails(
  BuildContext context, {
  required String kind,
  required String entityId,
  required String chatId,
  String? teamId,
  String? cardMessageId,
  String? title,
  void Function(String? cardMessageId)? onOpenDiscussion,
  ChatGroupActionsRepository? repository,
  ChatActionCardsCache? cache,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => UnifiedTaskDetailsScreen(
        kind: kind,
        entityId: entityId,
        chatId: chatId,
        teamId: teamId,
        cardMessageId: cardMessageId,
        title: title,
        onOpenDiscussion: onOpenDiscussion,
        repository: repository,
        cache: cache,
      ),
    ),
  );
}

class UnifiedTaskDetailsScreen extends StatefulWidget {
  const UnifiedTaskDetailsScreen({
    super.key,
    required this.kind,
    required this.entityId,
    required this.chatId,
    this.teamId,
    this.cardMessageId,
    this.title,
    this.onOpenDiscussion,
    this.repository,
    this.cache,
    this.client,
  });

  /// `topic_selection` | `collection` / `group_collection` | `assignment`.
  final String kind;
  final String entityId;
  final String chatId;
  final String? teamId;
  final String? cardMessageId;
  final String? title;

  /// Called after this screen pops, with the resolved card message id (if
  /// any) so the caller can scroll/highlight the originating chat bubble.
  final void Function(String? cardMessageId)? onOpenDiscussion;

  final ChatGroupActionsRepository? repository;
  final ChatActionCardsCache? cache;
  final SupabaseClient? client;

  @override
  State<UnifiedTaskDetailsScreen> createState() =>
      _UnifiedTaskDetailsScreenState();
}

class _UnifiedTaskDetailsScreenState extends State<UnifiedTaskDetailsScreen> {
  late final SupabaseClient _client = widget.client ?? Supabase.instance.client;
  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository(client: _client);
  late final ChatActionCardsCache _cache =
      widget.cache ?? ChatActionCardsCache.instance;

  String get _kind => ChatActionCardsCache.canonicalKind(widget.kind);

  Map<String, dynamic>? _details;
  bool _loading = true;
  String? _error;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    if (_kind != ChatActionCardKind.topicSelection &&
        _kind != ChatActionCardKind.groupCollection) {
      // Assignment (or unknown) kinds render immediately without a fetch.
      _loading = false;
      return;
    }
    final peeked = _cache.peek(_kind, widget.entityId);
    if (peeked != null && peeked.available) {
      _details = _entryToMap(peeked);
      _loading = false;
    }
    _load();
  }

  Map<String, dynamic> _entryToMap(ChatActionCardEntry e) => {
        'available': e.available,
        'status': e.status,
        'title': e.title,
        'description': e.description,
        'purpose': e.purpose,
        'row_version': e.rowVersion,
        'deadline_at': e.deadlineAt?.toIso8601String(),
        'allow_change': e.allowChange,
        'free_slots': e.freeSlots,
        'taken_slots': e.takenSlots,
        'total_capacity': e.totalCapacity,
        'my_pick_text': e.myPickText,
        'my_status': e.myStatus,
        'amount_mode': e.amountMode,
        'amount_optional': e.amountOptional,
        'amount_total': e.amountTotal,
        'compact_completed': e.compactCompleted,
        'organizer_stats': e.organizerStats,
        'can_manage': e.canManage,
        'options': e.options,
        'card_message_id': e.cardMessageId,
      };

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      final res = await _client.rpc('get_task_details', params: {
        'p_kind': _kind,
        'p_entity_id': widget.entityId,
        'p_chat_id': widget.chatId,
      });
      final map = _asMap(res);
      if (!mounted) return;
      if (map.isEmpty || map['available'] == false) {
        setState(() {
          _loading = false;
          if (_details == null) _error = 'Недоступно';
        });
        return;
      }
      setState(() {
        _details = map;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (_isMissingRpc(e)) {
        await _loadFallback();
        return;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_details == null) _error = 'Не удалось загрузить';
      });
    }
  }

  Future<void> _loadFallback() async {
    try {
      if (_kind == ChatActionCardKind.topicSelection) {
        final selections = await _repo.listTopicSelectionsForChat(widget.chatId,
            cacheFirst: true);
        final found = selections.where((s) => s.id == widget.entityId).toList();
        if (found.isEmpty) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            if (_details == null) _error = 'Не удалось загрузить';
          });
          return;
        }
        final s = found.first;
        final options = await _repo.listTopicOptionsForSelection(s.id);
        if (!mounted) return;
        setState(() {
          _details = {
            'available': true,
            'status': s.status,
            'title': s.title,
            'description': s.description,
            'deadline_at': s.deadlineAt?.toIso8601String(),
            'allow_change': s.allowChange,
            'free_slots': s.freeSlots,
            'taken_slots': s.takenSlots,
            'total_capacity': s.totalCapacity,
            'compact_completed': s.status != 'open',
            'can_manage': widget.repository != null ? null : false,
            'options': options
                .map((o) => {
                      'id': o.id,
                      'title': o.title,
                      'capacity': o.capacity,
                      'taken': o.taken,
                      'my_pick': o.myPick,
                    })
                .toList(),
          };
          _loading = false;
          _error = null;
        });
      } else if (_kind == ChatActionCardKind.groupCollection) {
        final res = await _client.rpc('list_group_collections');
        Map<String, dynamic>? found;
        if (res is List) {
          for (final row in res) {
            if (row is Map && row['id']?.toString() == widget.entityId) {
              found = Map<String, dynamic>.from(row);
              break;
            }
          }
        }
        if (!mounted) return;
        if (found == null) {
          setState(() {
            _loading = false;
            if (_details == null) _error = 'Не удалось загрузить';
          });
          return;
        }
        setState(() {
          _details = found;
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_details == null) _error = 'Не удалось загрузить';
      });
    }
  }

  bool _isMissingRpc(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('pgrst202') ||
        text.contains('could not find the function');
  }

  String? _resolvedCardMessageId() {
    return widget.cardMessageId ?? _details?['card_message_id']?.toString();
  }

  void _openDiscussion() {
    final id = _resolvedCardMessageId();
    Navigator.of(context).pop();
    widget.onOpenDiscussion?.call(id);
  }

  Future<void> _pickOption(Map<String, dynamic> option) async {
    if (_acting) return;
    final optionId = (option['id'] ?? '').toString();
    final title = (option['title'] ?? '').toString();
    if (optionId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подтвердить выбор'),
        content: Text('Выбрать тему «$title»?'),
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
      await _repo.pickTopic(selectionId: widget.entityId, optionId: optionId);
      await _cache.refreshEntity(
        widget.chatId,
        kind: ChatActionCardKind.topicSelection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать тему')),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _closeTopicSelection() async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await _repo.closeTopicSelection(selectionId: widget.entityId);
      await _cache.refreshEntity(
        widget.chatId,
        kind: ChatActionCardKind.topicSelection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось закрыть')),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  /// Author-before-activity: server SoT check mirrors
  /// `private.assert_topic_selection_mutable` (organizer OR author with zero
  /// picks so far). `get_task_details`/the cards batch RPC exposes
  /// `created_by`; ordinary (non-author, non-organizer) members never see
  /// the edit entry point.
  bool _canEditOwnBeforeActivity(Map<String, dynamic>? details) {
    if (details == null) return false;
    final myId = _client.auth.currentUser?.id;
    final createdBy = (details['created_by'] ?? '').toString();
    if (myId == null || myId.isEmpty || createdBy.isEmpty) return false;
    if (createdBy != myId) return false;
    return _asInt(details['taken_slots']) == 0;
  }

  Future<void> _openTopicEditor(Map<String, dynamic>? details) async {
    if (_acting || details == null) return;
    final options = (details['options'] as List?)
            ?.whereType<Map>()
            .map((e) => TopicEditRow.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        const <TopicEditRow>[];
    final changed = await openTopicOptionsEditor(
      context,
      chatId: widget.chatId,
      selectionId: widget.entityId,
      title: (details['title'] ?? '').toString(),
      description: (details['description'] ?? '').toString(),
      deadlineAt: DateTime.tryParse((details['deadline_at'] ?? '').toString()),
      allowChange: details['allow_change'] != false,
      selectionRowVersion: _asInt(details['row_version']),
      options: options,
      canManage: details['can_manage'] == true,
      canEditOwnBeforeActivity: _canEditOwnBeforeActivity(details),
      repository: _repo,
    );
    if (changed == true) {
      await _cache.refreshEntity(
        widget.chatId,
        kind: ChatActionCardKind.topicSelection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
      );
      await _load();
    }
  }

  Future<void> _deleteGroupAction(String kind) async {
    if (_acting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить?'),
        content: const Text('Действие будет отменено для всех участников.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      await _repo.deleteGroupAction(kind: kind, entityId: widget.entityId);
      _cache.markTombstone(_kind, widget.entityId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить')),
      );
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _markTransferred() async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await _repo.createCollectionContributionReport(widget.entityId);
      await _cache.refreshEntity(
        widget.chatId,
        kind: ChatActionCardKind.groupCollection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
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
      if (mounted) setState(() => _acting = false);
    }
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
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
    if (_kind == ChatActionCardKind.topicSelection ||
        _kind == ChatActionCardKind.groupCollection) {
      return _buildShell(context);
    }
    return _buildAssignment(context);
  }

  Widget _buildAssignment(BuildContext context) {
    try {
      context.read<TeamCubit>();
    } catch (_) {
      return Scaffold(
        appBar: AppBar(title: const Text('Задание')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Откройте это задание из чата команды.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        bottomNavigationBar: _discussionBar(),
      );
    }
    return AssignmentDetailsScreen(assignmentId: widget.entityId);
  }

  Widget? _discussionBar() {
    if (widget.onOpenDiscussion == null) return null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: OutlinedButton(
          onPressed: _openDiscussion,
          child: const Text('Открыть обсуждение'),
        ),
      ),
    );
  }

  Widget _buildShell(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isTopic = _kind == ChatActionCardKind.topicSelection;
    final details = _details;
    final title = (widget.title?.trim().isNotEmpty ?? false)
        ? widget.title!.trim()
        : (details?['title']?.toString() ??
            (isTopic ? 'Выбор темы' : 'Скинуться'));
    final closed = details != null &&
        (details['compact_completed'] == true ||
            (details['status']?.toString() ?? 'open') != 'open');
    final canManage = details?['can_manage'] == true;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(title),
        centerTitle: false,
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading && details == null
              ? _buildSkeleton()
              : (_error != null && details == null)
                  ? _buildError()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                      children: [
                        _Badge(
                          label: isTopic ? 'Выбор темы' : 'Скинуться',
                          color: isTopic ? cs.primary : cs.secondary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (closed) ...[
                          const SizedBox(height: 12),
                          _ClosedCompactCard(title: title),
                        ] else if (isTopic)
                          ..._buildTopicBody(context, details, canManage)
                        else
                          ..._buildCollectionBody(context, details, canManage),
                      ],
                    ),
        ),
      ),
      bottomNavigationBar: _discussionBar(),
    );
  }

  List<Widget> _buildTopicBody(
    BuildContext context,
    Map<String, dynamic>? details,
    bool canManage,
  ) {
    final theme = Theme.of(context);
    final description = (details?['description'] ?? '').toString().trim();
    final deadline =
        DateTime.tryParse((details?['deadline_at'] ?? '').toString());
    final taken = _asInt(details?['taken_slots']);
    final total = _asInt(details?['total_capacity']);
    final myPick = (details?['my_pick_text'] ?? '').toString().trim();
    final options = (details?['options'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];

    return [
      if (description.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(description, style: theme.textTheme.bodyMedium),
      ],
      const SizedBox(height: 10),
      Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          if (deadline != null)
            _MetaChip(icon: Icons.schedule, label: 'До ${_fmt(deadline)}'),
          if (total > 0)
            _MetaChip(
              icon: Icons.pie_chart_outline,
              label: 'Выбрано $taken из $total',
            ),
        ],
      ),
      if (myPick.isNotEmpty) ...[
        const SizedBox(height: 12),
        _MyStatusBanner(text: 'Ваша тема: $myPick'),
      ],
      if (canManage || _canEditOwnBeforeActivity(details)) ...[
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _acting ? null : () => _openTopicEditor(details),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('Редактировать темы'),
            ),
            if (canManage)
              OutlinedButton.icon(
                onPressed: _acting ? null : _closeTopicSelection,
                icon: const Icon(Icons.lock_outline, size: 18),
                label: const Text('Закрыть'),
              ),
            if (canManage)
              OutlinedButton.icon(
                onPressed: _acting ? null : () => _deleteGroupAction('topic'),
                icon: Icon(Icons.delete_outline,
                    size: 18, color: theme.colorScheme.error),
                label: Text('Удалить',
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      Text('Темы',
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      for (final o in options)
        _TopicOptionRow(
            option: o, onTap: () => _pickOption(o), enabled: !_acting),
      if (options.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Темы пока не добавлены',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
        ),
    ];
  }

  List<Widget> _buildCollectionBody(
    BuildContext context,
    Map<String, dynamic>? details,
    bool canManage,
  ) {
    final theme = Theme.of(context);
    final purpose = (details?['purpose'] ?? details?['description'] ?? '')
        .toString()
        .trim();
    final deadline =
        DateTime.tryParse((details?['deadline_at'] ?? '').toString());
    final amountMode = (details?['amount_mode'] ?? 'none').toString();
    final amountOptional = details?['amount_optional'];
    final amountTotal = details?['amount_total'];
    final myStatus = (details?['my_status'] ?? 'none').toString();
    final organizerStats = details?['organizer_stats'] is Map
        ? Map<String, dynamic>.from(details!['organizer_stats'] as Map)
        : null;

    String amountLabel() {
      if (amountMode == 'per_person' && amountOptional != null) {
        return 'По ${amountOptional.toString()} ₽ с человека';
      }
      if (amountMode == 'total' && amountTotal != null) {
        return 'Всего ${amountTotal.toString()} ₽';
      }
      return 'Сумма не фиксирована';
    }

    String myStatusLabel() {
      switch (myStatus) {
        case 'confirmed':
          return 'Подтверждено';
        case 'not_received':
          return 'Не поступило';
        case 'needs_clarification':
          return 'Уточнить';
        case 'reported':
        case 'pending_review':
        case 'pending':
          return 'Перевёл — на проверке';
        default:
          return 'Ожидает';
      }
    }

    return [
      if (purpose.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(purpose, style: theme.textTheme.bodyMedium),
      ],
      const SizedBox(height: 10),
      Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          _MetaChip(icon: Icons.payments_outlined, label: amountLabel()),
          if (deadline != null)
            _MetaChip(icon: Icons.schedule, label: 'До ${_fmt(deadline)}'),
        ],
      ),
      const SizedBox(height: 12),
      _MyStatusBanner(text: 'Мой статус: ${myStatusLabel()}'),
      if (organizerStats != null) ...[
        const SizedBox(height: 10),
        _MetaChip(
          icon: Icons.groups_outlined,
          label:
              'Подтверждено ${organizerStats['confirmed'] ?? 0} · Ожидают ${organizerStats['pending'] ?? organizerStats['total'] ?? 0}',
        ),
      ],
      const SizedBox(height: 16),
      FilledButton.tonal(
        onPressed: _acting ? null : _markTransferred,
        child: _acting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Я перевёл'),
      ),
      if (canManage) ...[
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _acting ? null : () => _deleteGroupAction('collection'),
          icon: Icon(Icons.delete_outline,
              size: 18, color: theme.colorScheme.error),
          label:
              Text('Удалить', style: TextStyle(color: theme.colorScheme.error)),
        ),
      ],
    ];
  }

  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: List.generate(
        4,
        (i) => Container(
          height: i == 0 ? 28 : 56,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F1F5),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? 'Не удалось загрузить'),
            const SizedBox(height: 12),
            FilledButton.tonal(
                onPressed: _load, child: const Text('Повторить')),
          ],
        ),
      ),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12.5,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _MyStatusBanner extends StatelessWidget {
  const _MyStatusBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: cs.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedCompactCard extends StatelessWidget {
  const _ClosedCompactCard({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.task_alt_rounded, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Задание завершено',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
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

class _TopicOptionRow extends StatelessWidget {
  const _TopicOptionRow({
    required this.option,
    required this.onTap,
    required this.enabled,
  });

  final Map<String, dynamic> option;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = (option['title'] ?? '').toString();
    final capacity = _asInt(option['capacity']);
    final taken = _asInt(option['taken']);
    final myPick = option['my_pick'] == true;
    final full = capacity > 0 && taken >= capacity && !myPick;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: myPick
            ? cs.primary.withValues(alpha: 0.10)
            : cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: (enabled && !full) ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        capacity > 0
                            ? 'Занято $taken из $capacity'
                            : 'Без ограничений',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (myPick)
                  Icon(Icons.check_circle_rounded, color: cs.primary)
                else if (full)
                  Icon(Icons.lock_outline, color: cs.onSurfaceVariant)
                else
                  Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
