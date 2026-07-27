import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:student_platform/src/navigation/root_nav.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';

Future<void> showNotificationCenterSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => const _NotificationCenterBody(),
  );
}

enum _NotifGroup { chats, assignments, actions }

extension on _NotifGroup {
  String get label {
    switch (this) {
      case _NotifGroup.chats:
        return 'Чаты';
      case _NotifGroup.assignments:
        return 'Задания';
      case _NotifGroup.actions:
        return 'Действия';
    }
  }

  IconData get icon {
    switch (this) {
      case _NotifGroup.chats:
        return Icons.chat_bubble_outline_rounded;
      case _NotifGroup.assignments:
        return Icons.assignment_outlined;
      case _NotifGroup.actions:
        return Icons.bolt_outlined;
    }
  }
}

_NotifGroup _groupFor(AppNotificationItem item) {
  switch (item.eventType) {
    case 'dm_message':
    case 'team_message':
    case 'team_reply':
      return _NotifGroup.chats;
    case 'assignment':
      return _NotifGroup.assignments;
    case 'topic_selection_created':
    case 'topic_deadline_soon':
    case 'topic_reassigned':
    case 'topic_pick_changed':
    case 'collection_created':
    case 'collection_deadline_soon':
    case 'collection_contribution_private':
      return _NotifGroup.actions;
    default:
      return _NotifGroup.actions;
  }
}

String _threadKey(AppNotificationItem item) {
  final chatId = (item.data['chat_id'] ?? '').toString().trim();
  if (chatId.isNotEmpty) return 'c:$chatId';
  final peerId = (item.data['peer_id'] ?? '').toString().trim();
  if (peerId.isNotEmpty) return 'p:$peerId';
  final assignmentId = (item.data['assignment_id'] ?? '').toString().trim();
  if (assignmentId.isNotEmpty) return 'a:$assignmentId';
  final selectionId = (item.data['selection_id'] ?? '').toString().trim();
  if (selectionId.isNotEmpty) return 'sel:$selectionId';
  final collectionId = (item.data['collection_id'] ?? '').toString().trim();
  if (collectionId.isNotEmpty) return 'col:$collectionId';
  return 'i:${item.id}';
}

class _ThreadSummary {
  _ThreadSummary({required this.key, required this.items});
  final String key;
  final List<AppNotificationItem> items;

  AppNotificationItem get latest => items.first;
  int get unreadCount => items.where((e) => e.isUnread).length;
  int get total => items.length;
}

class _NotificationCenterBody extends StatefulWidget {
  const _NotificationCenterBody();

  @override
  State<_NotificationCenterBody> createState() =>
      _NotificationCenterBodyState();
}

class _NotificationCenterBodyState extends State<_NotificationCenterBody> {
  final _api = AppNotificationsApi();
  List<AppNotificationItem> _items = const [];
  bool _loading = true;
  Object? _error;
  final Set<_NotifGroup> _expandedGroups = {};
  final Set<String> _expandedThreads = {};
  final Map<String, String> _peerNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _api.listMine(limit: 50);
      if (!mounted) return;
      setState(() => _items = items);
      await _hydratePeerTitles(items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _hydratePeerTitles(List<AppNotificationItem> items) async {
    final peerIds = <String>{};
    for (final item in items) {
      if (item.eventType != 'dm_message') continue;
      if (!isUnresolvedDmTitle(item.title)) continue;
      final peerId = (item.data['peer_id'] ?? '').toString().trim();
      if (peerId.isNotEmpty) peerIds.add(peerId);
    }
    if (peerIds.isEmpty) return;

    final missing =
        peerIds.where((id) => !_peerNames.containsKey(id)).toList();
    for (final id in missing) {
      final profile = await PushNavigation.resolvePeerProfile(id);
      if (!isUnresolvedDmTitle(profile.name)) {
        _peerNames[id] = profile.name;
      }
    }
    if (mounted) setState(() {});
  }

  String _displayTitle(AppNotificationItem item) {
    if (item.eventType == 'dm_message') {
      final peerId = (item.data['peer_id'] ?? '').toString().trim();
      final hydrated = _peerNames[peerId];
      if (hydrated != null && hydrated.isNotEmpty) return hydrated;
      return normalizeDmTitle(item.title);
    }
    final t = item.title.trim();
    return t.isEmpty ? 'Уведомление' : t;
  }

  Future<void> _markAllRead() async {
    await _api.markAllRead();
    await _load();
  }

  Future<void> _openItem(AppNotificationItem item) async {
    // Capture root context BEFORE closing the sheet — sheet context dies on pop.
    final payload = PushPayload.tryParse({
      'version': item.data['version']?.toString() ?? '1',
      'type': item.eventType,
      'notification_id': item.id,
      'title': _displayTitle(item),
      ...item.data.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    });

    if (item.isUnread) {
      try {
        await _api.markRead(item.id);
      } catch (_) {}
    }

    if (mounted) {
      Navigator.of(context).pop();
    }

    if (payload == null) return;
    // Force open even if same chat was opened recently.
    await PushNavigation.handle(
      rootNavigatorContext,
      payload,
      force: true,
    );
  }

  Map<_NotifGroup, List<_ThreadSummary>> _groupedThreads() {
    final byGroup = <_NotifGroup, Map<String, List<AppNotificationItem>>>{
      for (final g in _NotifGroup.values)
        g: <String, List<AppNotificationItem>>{},
    };

    for (final item in _items) {
      final g = _groupFor(item);
      final key = _threadKey(item);
      byGroup[g]!.putIfAbsent(key, () => <AppNotificationItem>[]).add(item);
    }

    final result = <_NotifGroup, List<_ThreadSummary>>{};
    for (final g in _NotifGroup.values) {
      final threads = byGroup[g]!
          .entries
          .map((e) {
            final list = List<AppNotificationItem>.from(e.value)
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            return _ThreadSummary(key: e.key, items: list);
          })
          .toList()
        ..sort((a, b) => b.latest.createdAt.compareTo(a.latest.createdAt));
      result[g] = threads;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.78;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Icon(Icons.notifications_none_rounded, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Уведомления',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  onPressed:
                      _items.any((e) => e.isUnread) ? _markAllRead : null,
                  child: const Text('Прочитать все'),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _buildList(theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    final cs = theme.colorScheme;

    if (_loading && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
        ],
      );
    }

    if (_error != null && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 40),
          Text(
            'Не удалось загрузить уведомления',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(color: cs.onSurface),
          ),
          const SizedBox(height: 12),
          Center(
            child: FilledButton(
              onPressed: _load,
              child: const Text('Повторить'),
            ),
          ),
        ],
      );
    }

    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 64),
          Icon(
            Icons.notifications_off_outlined,
            size: 48,
            color: cs.onSurface.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            'Пока нет уведомлений',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      );
    }

    final grouped = _groupedThreads();
    final children = <Widget>[];

    for (final group in _NotifGroup.values) {
      final threads = grouped[group] ?? const <_ThreadSummary>[];
      if (threads.isEmpty) continue;

      final unread =
          threads.fold<int>(0, (sum, t) => sum + t.unreadCount);
      final expanded = _expandedGroups.contains(group);
      // Collapsed: only the newest thread; expanded: all threads.
      final visible =
          expanded ? threads : threads.take(1).toList(growable: false);
      final hiddenCount = threads.length - visible.length;

      children.add(
        Padding(
          padding: EdgeInsets.fromLTRB(4, children.isEmpty ? 0 : 10, 4, 6),
          child: Material(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                setState(() {
                  if (expanded) {
                    _expandedGroups.remove(group);
                  } else {
                    _expandedGroups.add(group);
                  }
                });
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(group.icon, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (unread > 0)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$unread',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onPrimary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    Text(
                      '${threads.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.45),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      for (final thread in visible) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ThreadCard(
              thread: thread,
              title: _displayTitle(thread.latest),
              expanded: _expandedThreads.contains(thread.key),
              onToggleExpand: thread.total > 1
                  ? () {
                      setState(() {
                        if (_expandedThreads.contains(thread.key)) {
                          _expandedThreads.remove(thread.key);
                        } else {
                          _expandedThreads.add(thread.key);
                        }
                      });
                    }
                  : null,
              onOpenLatest: () => _openItem(thread.latest),
              onOpenItem: _openItem,
              onHideLatest: () async {
                await _api.hide(thread.latest.id);
                await _load();
              },
            ),
          ),
        );
      }

      if (!expanded && hiddenCount > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: TextButton.icon(
              onPressed: () => setState(() => _expandedGroups.add(group)),
              icon: const Icon(Icons.unfold_more_rounded, size: 18),
              label: Text('Ещё $hiddenCount'),
            ),
          ),
        );
      }
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: children,
    );
  }
}

class _ThreadCard extends StatelessWidget {
  const _ThreadCard({
    required this.thread,
    required this.title,
    required this.expanded,
    required this.onOpenLatest,
    required this.onOpenItem,
    required this.onHideLatest,
    this.onToggleExpand,
  });

  final _ThreadSummary thread;
  final String title;
  final bool expanded;
  final VoidCallback onOpenLatest;
  final void Function(AppNotificationItem item) onOpenItem;
  final VoidCallback onHideLatest;
  final VoidCallback? onToggleExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final latest = thread.latest;
    final time = DateFormat('d MMM, HH:mm', 'ru_RU').format(latest.createdAt);
    final unread = thread.unreadCount > 0;

    final bg = unread ? cs.primaryContainer : cs.surfaceContainerHighest;
    final titleColor = unread ? cs.onPrimaryContainer : cs.onSurface;
    final bodyColor = unread
        ? cs.onPrimaryContainer.withValues(alpha: 0.88)
        : cs.onSurface.withValues(alpha: 0.78);
    final metaColor = unread
        ? cs.onPrimaryContainer.withValues(alpha: 0.62)
        : cs.onSurface.withValues(alpha: 0.5);

    final subtitle = thread.total > 1
        ? '${latest.body}\n${thread.total} сообщ.'
            '${thread.unreadCount > 0 ? ' · ${thread.unreadCount} новых' : ''}'
        : latest.body;

    return Material(
      color: bg,
      elevation: unread ? 0.5 : 0,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        children: [
          InkWell(
            borderRadius: expanded
                ? const BorderRadius.vertical(top: Radius.circular(16))
                : BorderRadius.circular(16),
            onTap: onOpenLatest,
            onLongPress: onHideLatest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(top: 5, right: 10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: unread ? cs.primary : Colors.transparent,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight:
                                unread ? FontWeight.w800 : FontWeight.w600,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: expanded ? 4 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.35,
                            color: bodyColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          time,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: metaColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onToggleExpand != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggleExpand,
                      icon: Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: titleColor.withValues(alpha: 0.7),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (expanded && thread.total > 1)
            ...thread.items.skip(1).take(8).map((item) {
              final t =
                  DateFormat('d MMM, HH:mm', 'ru_RU').format(item.createdAt);
              return InkWell(
                onTap: () => onOpenItem(item),
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.fromLTRB(34, 8, 14, 10),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: cs.onSurface.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: bodyColor,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: metaColor,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
