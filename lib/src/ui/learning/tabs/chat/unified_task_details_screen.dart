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
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../assignment_details_screen.dart';
import '../../state/team_cubit.dart';
import '../../../group_space/data/group_space_repository.dart';
import 'data/chat_action_cards_cache.dart';
import 'data/chat_group_actions_repository.dart';
import 'models/group_action_labels.dart';
import 'topics/topic_options_editor_screen.dart';

/// Author-only gate for editing the published topic option list.
///
/// Matches product rule: the creator may edit themes only before anyone has
/// picked. Organizers keep close/delete separately — they do not get this
/// entry point unless they are also the author with zero picks.
bool canAuthorEditTopicSelectionBeforeActivity({
  required String? currentUserId,
  required Map<String, dynamic>? details,
}) {
  if (details == null) return false;
  final myId = (currentUserId ?? '').trim();
  final createdBy = (details['created_by'] ?? '').toString().trim();
  if (myId.isEmpty || createdBy.isEmpty || createdBy != myId) return false;
  final taken = details['taken_slots'];
  final takenSlots = taken is int
      ? taken
      : taken is num
          ? taken.toInt()
          : int.tryParse(taken?.toString() ?? '') ?? 0;
  return takenSlots == 0;
}

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
  /// Prefer the root navigator so in-chat opens match schedule/home deeplinks
  /// (otherwise a nested TeamDetails navigator can swallow the route).
  bool useRootNavigator = true,
}) {
  return Navigator.of(context, rootNavigator: useRootNavigator).push(
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
  bool _canDeleteEntity = false;
  String? _proofPath;
  String? _proofName;
  List<Map<String, dynamic>> _contributions = const [];
  late final GroupSpaceRepository _spaceRepo =
      GroupSpaceRepository(client: _client);

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
        'created_by': e.createdBy,
        'options': e.options,
        'card_message_id': e.cardMessageId,
      };

  Future<void> _refreshCanDelete() async {
    try {
      final allowed = await _repo.canDeleteGroupAction(
        kind: _kind,
        entityId: widget.entityId,
      );
      if (!mounted) return;
      setState(() => _canDeleteEntity = allowed);
    } catch (_) {
      if (!mounted) return;
      // Fail closed if capability RPC is unavailable.
      setState(() => _canDeleteEntity = false);
    }
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      // Always go through the repository so tests/fakes can inject details
      // without a live RPC client.
      final map = await _repo.getTaskDetails(
        chatId: widget.chatId,
        kind: _kind,
        entityId: widget.entityId,
      );
      if (!mounted) return;
      if (map.isEmpty || map['available'] == false) {
        setState(() {
          _loading = false;
          _canDeleteEntity = false;
          if (_details == null) _error = 'Недоступно';
        });
        return;
      }
      final fromDetails = map['can_delete'];
      setState(() {
        _details = map;
        _loading = false;
        _error = null;
        if (fromDetails is bool) _canDeleteEntity = fromDetails;
      });
      if (fromDetails is! bool) {
        await _refreshCanDelete();
      }
      if (_kind == ChatActionCardKind.groupCollection &&
          map['can_manage'] == true) {
        await _loadContributions();
      }
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

  Future<void> _loadContributions() async {
    try {
      final rows =
          await _repo.listCollectionContributionProgress(widget.entityId);
      final enriched = <Map<String, dynamic>>[];
      for (final row in rows) {
        final userId = (row['user_id'] ?? '').toString();
        final hasProof = row['has_proof'] == true ||
            (row['proof_file_id']?.toString() ?? '').isNotEmpty;
        Map<String, dynamic>? proof;
        if (hasProof && userId.isNotEmpty) {
          try {
            proof = await _repo.getCollectionProofFile(
              collectionId: widget.entityId,
              userId: userId,
            );
          } catch (_) {}
        }
        enriched.add({
          ...row,
          'proof_file_url': proof?['file_url'],
          'proof_file_name': proof?['file_name'],
          'display_name': _shortUserLabel(userId),
        });
      }
      if (!mounted) return;
      setState(() => _contributions = enriched);
    } catch (_) {
      if (!mounted) return;
      setState(() => _contributions = const []);
    }
  }

  String _shortUserLabel(String userId) {
    if (userId.length <= 8) return userId;
    return '${userId.substring(0, 8)}…';
  }

  Future<void> _pickProof() async {
    if (_acting) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Галерея'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Камера'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Файл'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'file') {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );
      final path = result?.files.single.path;
      final name = result?.files.single.name;
      if (path == null || path.isEmpty || !mounted) return;
      setState(() {
        _proofPath = path;
        _proofName = (name ?? path.split('/').last).trim();
      });
      return;
    }

    final source =
        choice == 'camera' ? ImageSource.camera : ImageSource.gallery;
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _proofPath = picked.path;
      _proofName = picked.name.trim().isNotEmpty
          ? picked.name.trim()
          : picked.path.split('/').last;
    });
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

  Future<void> _toggleOption(Map<String, dynamic> option) async {
    if (_acting) return;
    final optionId = (option['id'] ?? '').toString();
    if (optionId.isEmpty) return;
    final myPick = option['my_pick'] == true;
    final allowChange = _details?['allow_change'] != false;
    final capacity = _asInt(option['capacity']);
    final taken = _asInt(option['taken']);
    final full = capacity > 0 && taken >= capacity && !myPick;

    if (myPick) {
      if (!allowChange) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Смену темы отключил автор')),
        );
        return;
      }
      setState(() => _acting = true);
      try {
        await _repo.cancelTopicPick(widget.entityId);
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
          const SnackBar(content: Text('Не удалось снять выбор')),
        );
      } finally {
        if (mounted) setState(() => _acting = false);
      }
      return;
    }

    if (full) return;
    final hasOwnPick =
        (_details?['my_pick_text'] ?? '').toString().trim().isNotEmpty;
    if (hasOwnPick && !allowChange) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Смену темы отключил автор')),
      );
      return;
    }

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

  bool _canEditOwnBeforeActivity(Map<String, dynamic>? details) {
    return canAuthorEditTopicSelectionBeforeActivity(
      currentUserId: _client.auth.currentUser?.id,
      details: details,
    );
  }

  bool _isCurrentUserAuthor(Map<String, dynamic>? details) {
    final myId = (_client.auth.currentUser?.id ?? '').trim();
    final createdBy = (details?['created_by'] ?? '').toString().trim();
    return myId.isNotEmpty && createdBy.isNotEmpty && myId == createdBy;
  }

  bool _showDeleteAction(bool canManage) {
    // Prefer server capability; organizers keep delete via can_manage fallback
    // only when capability RPC has not answered yet and details say manage.
    return _canDeleteEntity || canManage;
  }

  bool _canRescheduleTopic(Map<String, dynamic>? details, bool canManage) {
    return canManage || _canEditOwnBeforeActivity(details);
  }

  bool _canRescheduleCollection(Map<String, dynamic>? details, bool canManage) {
    if (!kCollectionDeadlineRescheduleEnabled) return false;
    return canManage || _isCurrentUserAuthor(details);
  }

  List<_OverflowAction> _overflowActions({
    required bool isTopic,
    required Map<String, dynamic>? details,
    required bool canManage,
  }) {
    if (details == null || _loading) return const [];
    final out = <_OverflowAction>[];
    if (isTopic) {
      if (_canRescheduleTopic(details, canManage)) {
        final hasDeadline =
            DateTime.tryParse((details['deadline_at'] ?? '').toString()) != null;
        out.add(
          hasDeadline
              ? _OverflowAction.reschedule
              : _OverflowAction.assignDeadline,
        );
      }
      if (_canEditOwnBeforeActivity(details)) {
        out.add(_OverflowAction.editTopics);
      }
      if (canManage) {
        out.add(_OverflowAction.close);
      }
      if (_showDeleteAction(canManage)) {
        out.add(_OverflowAction.delete);
      }
    } else {
      if (_canRescheduleCollection(details, canManage)) {
        final hasDeadline =
            DateTime.tryParse((details['deadline_at'] ?? '').toString()) != null;
        out.add(
          hasDeadline
              ? _OverflowAction.reschedule
              : _OverflowAction.assignDeadline,
        );
      }
      if (_showDeleteAction(canManage)) {
        out.add(_OverflowAction.delete);
      }
    }
    return out;
  }

  Future<void> _onOverflowSelected(
    _OverflowAction action, {
    required Map<String, dynamic>? details,
  }) async {
    if (_acting || details == null) return;
    final deadline =
        DateTime.tryParse((details['deadline_at'] ?? '').toString());
    switch (action) {
      case _OverflowAction.reschedule:
      case _OverflowAction.assignDeadline:
        await _rescheduleDeadline(
          kind: _kind == ChatActionCardKind.topicSelection
              ? 'topic_selection'
              : 'collection',
          current: deadline,
          rowVersion: _asInt(details['row_version']),
        );
      case _OverflowAction.editTopics:
        await _openTopicEditor(details);
      case _OverflowAction.close:
        await _closeTopicSelection();
      case _OverflowAction.delete:
        await _deleteGroupAction(
          _kind == ChatActionCardKind.topicSelection ? 'topic' : 'collection',
        );
    }
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
      // List edits are author-before-activity only (not organizer moderate).
      canManage: false,
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
        const SnackBar(
          content: Text(
            'Не удалось удалить. Возможно, уже есть активность участников.',
          ),
        ),
      );
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _markTransferred() async {
    if (_acting) return;
    setState(() => _acting = true);
    String? uploadedProofId;
    try {
      if (_proofPath != null) {
        uploadedProofId = await _spaceRepo.uploadProofFile(
          chatId: widget.chatId,
          localPath: _proofPath!,
        );
      }
      await _repo.createCollectionContributionReport(
        widget.entityId,
        proofFileId: uploadedProofId,
      );
      await _cache.refreshEntity(
        widget.chatId,
        kind: ChatActionCardKind.groupCollection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
      );
      if (!mounted) return;
      setState(() {
        _proofPath = null;
        _proofName = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            uploadedProofId == null
                ? 'Отмечено как исполнено'
                : 'Отмечено как исполнено · файл прикреплён',
          ),
        ),
      );
      await _load();
    } catch (_) {
      // Orphan chat_files row (if any) is acceptable; user can retry attach.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отметить перевод')),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _reviewContribution(String userId, String status) async {
    if (_acting || userId.isEmpty) return;
    setState(() => _acting = true);
    try {
      await _repo.confirmCollectionContribution(
        collectionId: widget.entityId,
        userId: userId,
        paymentStatus: status,
      );
      await _cache.refreshEntity(
        widget.chatId,
        kind: ChatActionCardKind.groupCollection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
      );
      await _load();
      await _loadContributions();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось обновить статус')),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _openProofUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Date+time picker that preserves the existing clock time when only the
  /// calendar day changes (avoids silently resetting timezone/time).
  Future<void> _rescheduleDeadline({
    required String kind,
    DateTime? current,
    int? rowVersion,
  }) async {
    if (_acting) return;
    final now = DateTime.now();
    final base = (current ?? now.add(const Duration(days: 7))).toLocal();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: 'Новый срок',
      cancelText: 'Отмена',
      confirmText: 'Далее',
    );
    if (pickedDate == null || !mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      helpText: 'Время',
      cancelText: 'Отмена',
      confirmText: 'Сохранить',
    );
    if (pickedTime == null || !mounted) return;
    final next = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    setState(() => _acting = true);
    try {
      if (kind == 'topic_selection') {
        await _repo.updateTopicSelection(
          selectionId: widget.entityId,
          expectedVersion: rowVersion ?? 0,
          deadlineAt: next,
        );
      } else {
        await _repo.updateCollectionDeadline(
          collectionId: widget.entityId,
          deadlineAt: next,
          expectedVersion: rowVersion,
        );
      }
      await _cache.refreshEntity(
        widget.chatId,
        kind: kind == 'topic_selection'
            ? ChatActionCardKind.topicSelection
            : ChatActionCardKind.groupCollection,
        entityId: widget.entityId,
        cardMessageId: _resolvedCardMessageId(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Срок перенесён на ${_fmt(next)}')),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось перенести срок. Проверьте права доступа.'),
        ),
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
            (isTopic ? kTopicKindLabel : kCollectionKindLabel));
    final closed = details != null &&
        (details['compact_completed'] == true ||
            (details['status']?.toString() ?? 'open') != 'open');
    final canManage = details?['can_manage'] == true;
    final myPick = (details?['my_pick_text'] ?? '').toString().trim();
    final displayTitle = (!closed &&
            isTopic &&
            myPick.isNotEmpty)
        ? topicFollowUpTitle(myPick)
        : title;
    final kindLabel =
        isTopic ? kTopicKindLabel : kCollectionKindLabelLong;

    final titleColor = cs.onSurface;
    final overflow = closed
        ? const <_OverflowAction>[]
        : _overflowActions(
            isTopic: isTopic,
            details: details,
            canManage: canManage,
          );
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        // Kind only in the app bar — task title lives once in the body.
        title: Text(
          kindLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: titleColor,
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: false,
        foregroundColor: titleColor,
        actions: [
          if (overflow.isNotEmpty)
            PopupMenuButton<_OverflowAction>(
              tooltip: 'Ещё',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (action) => _onOverflowSelected(
                action,
                details: details,
              ),
              itemBuilder: (ctx) => [
                for (final action in overflow)
                  PopupMenuItem(
                    value: action,
                    child: Text(
                      action.label,
                      style: TextStyle(
                        color: action.destructive
                            ? Theme.of(ctx).colorScheme.error
                            : null,
                        fontWeight: action.destructive
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
        ],
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
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      children: [
                        Text(
                          displayTitle,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: titleColor,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                        if (!closed &&
                            isTopic &&
                            myPick.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Список: $title',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        if (closed) ...[
                          const SizedBox(height: 12),
                          _ClosedCompactCard(
                            label: isTopic
                                ? kTopicClosedLabel
                                : kCollectionClosedLabel,
                          ),
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
            _MetaChip(icon: Icons.schedule, label: 'Срок: ${_fmt(deadline)}'),
          if (total > 0)
            _MetaChip(
              icon: Icons.pie_chart_outline,
              label: 'Занято $taken из $total',
            ),
        ],
      ),
      if (myPick.isNotEmpty) ...[
        const SizedBox(height: 12),
        const _MyStatusBanner(
          text: 'Тема занята',
          tone: _StatusTone.success,
        ),
      ],
      const SizedBox(height: 16),
      Text(
        'Темы',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurface,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'Отметьте тему галочкой — повторное нажатие снимет выбор',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      for (final o in options)
        _TopicOptionRow(
            option: o, onTap: () => _toggleOption(o), enabled: !_acting),
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
      String money(dynamic raw) {
        if (raw is num) {
          final v = raw.toDouble();
          return v == v.roundToDouble()
              ? v.toInt().toString()
              : v.toStringAsFixed(2);
        }
        return raw.toString();
      }

      if (amountMode == 'per_person' && amountOptional != null) {
        return 'По ${money(amountOptional)} ₽ с человека';
      }
      if (amountMode == 'total' && amountTotal != null) {
        return 'Всего ${money(amountTotal)} ₽';
      }
      return 'Сумма не фиксирована';
    }

    final done = collectionParticipantIsDone(myStatus);
    final myStatusLabel = collectionParticipantStatusLabel(myStatus);

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
            _MetaChip(icon: Icons.schedule, label: 'Срок: ${_fmt(deadline)}'),
        ],
      ),
      const SizedBox(height: 12),
      _MyStatusBanner(
        text: 'Мой статус: $myStatusLabel',
        tone: done ? _StatusTone.success : _StatusTone.neutral,
      ),
      if (organizerStats != null) ...[
        const SizedBox(height: 10),
        _MetaChip(
          icon: Icons.groups_outlined,
          label:
              'Подтверждено ${organizerStats['confirmed'] ?? 0} · Ожидают ${organizerStats['pending'] ?? organizerStats['total'] ?? 0}',
        ),
      ],
      if (!done) ...[
        const SizedBox(height: 12),
        Text(
          'Прикрепите чек или скриншот перевода — его увидит только организатор.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _acting ? null : _pickProof,
          icon: const Icon(Icons.attach_file, size: 18),
          label: Text(
            _proofPath == null
                ? 'Прикрепить чек или скриншот'
                : (_proofName ?? 'Файл выбран'),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.tonal(
          onPressed: _acting ? null : _markTransferred,
          child: _acting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _proofPath == null
                      ? 'Отметить исполненным'
                      : 'Отметить с файлом',
                ),
        ),
      ],
      if (canManage) ...[
        const SizedBox(height: 18),
        Text(
          'Участники сбора',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Скриншоты видит только организатор',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_contributions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('Отметок пока нет'),
          )
        else
          ..._contributions.map((row) {
            final userId = (row['user_id'] ?? '').toString();
            final payment = (row['payment_status'] ?? 'unmarked').toString();
            final proofUrl = (row['proof_file_url'] ?? '').toString();
            final hasProof = proofUrl.isNotEmpty || row['has_proof'] == true;
            final name = (row['display_name'] ?? _shortUserLabel(userId))
                .toString();
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(name),
              subtitle: Text(
                '${_paymentLabel(payment)}${hasProof ? ' · есть скрин' : ''}',
              ),
              trailing: Wrap(
                spacing: 0,
                children: [
                  if (proofUrl.isNotEmpty)
                    IconButton(
                      tooltip: 'Открыть скрин',
                      onPressed: () => _openProofUrl(proofUrl),
                      icon: const Icon(Icons.open_in_new, size: 20),
                    ),
                  if (payment != 'confirmed') ...[
                    IconButton(
                      tooltip: 'Получено',
                      onPressed: _acting
                          ? null
                          : () => _reviewContribution(userId, 'confirmed'),
                      icon: const Icon(Icons.check_circle_outline, size: 20),
                    ),
                    IconButton(
                      tooltip: 'Не поступило',
                      onPressed: _acting
                          ? null
                          : () => _reviewContribution(userId, 'not_received'),
                      icon: const Icon(Icons.cancel_outlined, size: 20),
                    ),
                    IconButton(
                      tooltip: 'Уточнить',
                      onPressed: _acting
                          ? null
                          : () => _reviewContribution(
                                userId,
                                'needs_clarification',
                              ),
                      icon: const Icon(Icons.help_outline, size: 20),
                    ),
                  ],
                ],
              ),
            );
          }),
      ],
    ];
  }

  String _paymentLabel(String status) {
    switch (status) {
      case 'confirmed':
        return 'Подтверждено';
      case 'not_received':
        return 'Не поступило';
      case 'needs_clarification':
        return 'Нужно уточнение';
      case 'reported':
      case 'pending_review':
      case 'pending':
        // Organizer queue: participant already marked done; awaits confirm.
        return 'Ожидает подтверждения';
      default:
        return 'Ожидает';
    }
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


class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Soft rectangle — not a purple kind-pill; metadata only.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
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

enum _StatusTone { neutral, pending, success }

class _MyStatusBanner extends StatelessWidget {
  const _MyStatusBanner({
    required this.text,
    this.tone = _StatusTone.neutral,
  });
  final String text;
  final _StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (tone) {
      _StatusTone.success => const Color(0xFF2F9D84),
      _StatusTone.pending => const Color(0xFF2F9D84),
      _StatusTone.neutral => cs.primary,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedCompactCard extends StatelessWidget {
  const _ClosedCompactCard({
    this.label = kTopicClosedLabel,
  });
  final String label;

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
            child: Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
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
            : cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: (enabled && (!full || myPick)) ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  myPick
                      ? Icons.check_circle_rounded
                      : full
                          ? Icons.lock_outline
                          : Icons.radio_button_unchecked,
                  color: myPick
                      ? cs.primary
                      : full
                          ? cs.onSurfaceVariant
                          : cs.onSurfaceVariant.withValues(alpha: 0.7),
                  size: 26,
                ),
                const SizedBox(width: 12),
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
                        myPick
                            ? 'Ваш выбор · нажмите, чтобы снять'
                            : full
                                ? 'Занято'
                                : capacity > 0
                                    ? 'Свободно ${capacity - taken} из $capacity'
                                    : 'Свободна',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
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

enum _OverflowAction {
  reschedule('Перенести срок'),
  assignDeadline('Назначить срок'),
  editTopics('Редактировать темы'),
  close('Закрыть список'),
  delete('Удалить', destructive: true);

  const _OverflowAction(this.label, {this.destructive = false});
  final String label;
  final bool destructive;
}
