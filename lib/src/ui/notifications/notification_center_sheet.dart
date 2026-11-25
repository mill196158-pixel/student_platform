import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  static const _pageSize = 50;
  final _api = AppNotificationsApi();
  final _owner = Supabase.instance.client.auth.currentUser?.id;
  List<AppNotificationItem> _items = const [];
  bool _loading = true;
  bool _canMarkAll = false;
  bool _markingAll = false;
  int _loadNumber = 0;
  String? _actionError;
  bool get _current =>
      mounted && _owner == Supabase.instance.client.auth.currentUser?.id;
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
    if (!_current) return;
    final load = ++_loadNumber;
    bool current() => _current && load == _loadNumber;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _api.listMine(limit: _pageSize);
      if (!current()) return;
      var canMarkAll = items.any((item) => item.isUnread);
      if (!canMarkAll && items.length == _pageSize) {
        try {
          canMarkAll = await _api.unreadCount() > 0;
        } catch (_) {
          // Older rows may still be unread. The bulk operation is idempotent.
          canMarkAll = true;
        }
      }
      if (!current()) return;
      setState(() {
        _items = items;
        _canMarkAll = canMarkAll;
      });
      await _hydratePeerTitles(items, current);
    } catch (e) {
      if (!current()) return;
      setState(() => _error = e);
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  Future<void> _hydratePeerTitles(
      List<AppNotificationItem> items, bool Function() current) async {
    final peerIds = <String>{};
    for (final item in items) {
      if (item.eventType != 'dm_message') continue;
      if (!isUnresolvedDmTitle(item.title)) continue;
      final peerId = (item.data['peer_id'] ?? '').toString().trim();
      if (peerId.isNotEmpty) peerIds.add(peerId);
    }
    if (peerIds.isEmpty) return;

    final missing = peerIds.where((id) => !_peerNames.containsKey(id)).toList();
    for (final id in missing) {
      final profile = await PushNavigation.resolvePeerProfile(id);
      if (!current()) return;
      if (!isUnresolvedDmTitle(profile.name)) {
        _peerNames[id] = profile.name;
      }
    }
    if (current()) setState(() {});
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
    if (!_current || _markingAll || !_canMarkAll) return;
    setState(() {
      _markingAll = true;
      _actionError = null;
    });
    try {
      await _api.markAllRead();
      if (_current) await _load();
    } catch (_) {
      if (_current)
        setState(() =>
            _actionError = 'Не удалось отметить уведомления прочитанными');
    } finally {
      if (_current) setState(() => _markingAll = false);
    }
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
      final threads = byGroup[g]!.entries.map((e) {
        final list = List<AppNotificationItem>.from(e.value)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return _ThreadSummary(key: e.key, items: list);
      }).toList()
        ..sort((a, b) => b.latest.createdAt.compareTo(a.latest.createdAt));
      result[g] = threads;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 360 ||
        MediaQuery.textScalerOf(context).scale(16) > 20;
    final canMarkAll = _current && _canMarkAll && !_markingAll;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
              child: Row(children: [
                Expanded(
                    child: Semantics(
                        header: true,
                        child: Text(
                          'Уведомления',
                          style: theme.textTheme.headlineSmall,
                        ))),
                if (_items.isNotEmpty && compact)
                  IconButton(
                    tooltip: 'Прочитать все',
                    onPressed: canMarkAll ? _markAllRead : null,
                    icon: const Icon(Icons.done_all_rounded),
                  )
                else if (_items.isNotEmpty)
                  TextButton(
                      style: TextButton.styleFrom(
                          textStyle: theme.textTheme.bodyMedium),
                      onPressed: canMarkAll ? _markAllRead : null,
                      child: const Text('Прочитать все')),
              ]),
            ),
            Divider(height: 1, color: cs.outlineVariant),
            if (_actionError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Semantics(
                    liveRegion: true,
                    child:
                        Text(_actionError!, style: TextStyle(color: cs.error))),
              ),
            Expanded(
                child: RefreshIndicator(
                    onRefresh: _load, child: _buildList(theme))),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    final cs = theme.colorScheme;
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 68, 24, 24),
        children: [
          if (_loading)
            const Center(child: ProductLoadingIndicator.page())
          else ...[
            Icon(
                _error != null
                    ? Icons.cloud_off_outlined
                    : Icons.notifications_none_rounded,
                size: 36,
                color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
                _error != null
                    ? 'Не удалось загрузить уведомления'
                    : 'Пока нет уведомлений',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Center(
                  child: FilledButton(
                      onPressed: _load, child: const Text('Повторить'))),
            ],
          ],
        ],
      );
    }
    final grouped = _groupedThreads();
    final children = <Widget>[];
    for (final group in _NotifGroup.values) {
      final threads = grouped[group]!;
      if (threads.isEmpty) continue;
      final unread =
          threads.fold<int>(0, (sum, thread) => sum + thread.unreadCount);
      final expanded = _expandedGroups.contains(group);
      final canExpand = threads.length > 1;
      void toggleGroup() => setState(() {
            if (expanded) {
              _expandedGroups.remove(group);
            } else {
              _expandedGroups.add(group);
            }
          });
      children.add(Padding(
        padding: EdgeInsets.only(top: children.isEmpty ? 8 : 12),
        child: InkWell(
          onTap: canExpand ? toggleGroup : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(children: [
              Icon(group.icon, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                  child: Row(children: [
                Flexible(
                    child: Semantics(
                        header: true,
                        child: Text(group.label,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)))),
                if (unread > 0) ...[
                  const SizedBox(width: 8),
                  Semantics(
                      label: 'Непрочитанных: $unread',
                      excludeSemantics: true,
                      child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(6)),
                          child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              child: Text('$unread',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w700))))),
                ],
              ])),
              if (canExpand) ...[
                const SizedBox(width: 8),
                Text(expanded ? 'Свернуть' : 'Ещё ${threads.length - 1}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.primary, fontWeight: FontWeight.w600)),
                Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: cs.primary),
              ],
            ]),
          ),
        ),
      ));
      for (final thread in expanded ? threads : threads.take(1)) {
        final open = _expandedThreads.contains(thread.key);
        children.add(_ThreadRow(
          thread: thread,
          title: _displayTitle(thread.latest),
          expanded: open,
          onOpenLatest: () => _openItem(thread.latest),
          onOpenItem: _openItem,
          onHideLatest: () async {
            await _api.hide(thread.latest.id);
            if (mounted) await _load();
          },
          onToggle: () => setState(() {
            if (open) {
              _expandedThreads.remove(thread.key);
            } else {
              _expandedThreads.add(thread.key);
            }
          }),
        ));
      }
    }
    return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: children);
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow(
      {required this.thread,
      required this.title,
      required this.expanded,
      required this.onOpenLatest,
      required this.onOpenItem,
      required this.onHideLatest,
      required this.onToggle});

  final _ThreadSummary thread;
  final String title;
  final bool expanded;
  final VoidCallback onOpenLatest, onHideLatest, onToggle;
  final void Function(AppNotificationItem item) onOpenItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final latest = thread.latest;
    final unread = thread.unreadCount > 0;
    final timestamp = DateFormat('d MMM, HH:mm', 'ru_RU');
    final meta =
        theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
          onTap: onOpenLatest,
          onLongPress: onHideLatest,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  width: 30,
                  child: unread
                      ? Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: Semantics(
                                label: 'Есть непрочитанные',
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: cs.primary),
                                  child: const SizedBox.square(dimension: 7),
                                ),
                              )),
                        )
                      : null),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w500)),
                    if (latest.body.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(latest.body,
                          maxLines: expanded ? 4 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 5),
                    Text(timestamp.format(latest.createdAt), style: meta),
                  ])),
            ]),
          )),
      if (thread.total > 1)
        Padding(
            padding: const EdgeInsets.only(left: 22),
            child: TextButton.icon(
              style:
                  TextButton.styleFrom(textStyle: theme.textTheme.bodyMedium),
              onPressed: onToggle,
              icon: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18),
              label: Text(
                  expanded ? 'Свернуть историю' : 'История (${thread.total})'),
            )),
      if (expanded)
        for (final item in thread.items.skip(1).take(8))
          Padding(
              padding: const EdgeInsets.only(left: 30),
              child: InkWell(
                onTap: () => onOpenItem(item),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 48),
                  margin: const EdgeInsets.only(left: 2),
                  padding: const EdgeInsets.fromLTRB(14, 6, 0, 8),
                  decoration: BoxDecoration(
                      border: Border(
                          left:
                              BorderSide(color: cs.outlineVariant, width: 2))),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.body.trim().isEmpty ? item.title : item.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium),
                        Text(timestamp.format(item.createdAt), style: meta),
                      ]),
                ),
              )),
      Divider(height: 1, indent: 30, color: cs.outlineVariant),
    ]);
  }
}
