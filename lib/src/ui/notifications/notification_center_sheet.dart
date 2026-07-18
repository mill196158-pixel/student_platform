import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';

Future<void> showNotificationCenterSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => const _NotificationCenterBody(),
  );
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead() async {
    await _api.markAllRead();
    await _load();
  }

  Future<void> _openItem(AppNotificationItem item) async {
    if (item.isUnread) {
      await _api.markRead(item.id);
    }

    if (!mounted) return;
    Navigator.of(context).pop();

    final payload = PushPayload.tryParse({
      'version': item.data['version']?.toString() ?? '1',
      'type': item.eventType,
      'notification_id': item.id,
      ...item.data.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    });
    if (payload == null) return;
    await PushNavigation.handle(context, payload);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.78;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Icon(
                  Icons.notifications_none_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Уведомления',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
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
            style: theme.textTheme.titleMedium,
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
            color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            'Пока нет уведомлений',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = _items[index];
        return _NotificationCard(
          item: item,
          onTap: () => _openItem(item),
          onHide: () async {
            await _api.hide(item.id);
            await _load();
          },
        );
      },
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.item,
    required this.onTap,
    required this.onHide,
  });

  final AppNotificationItem item;
  final VoidCallback onTap;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final time = DateFormat('d MMM, HH:mm', 'ru_RU').format(item.createdAt);
    final unread = item.isUnread;

    return Material(
      color: unread
          ? cs.primaryContainer.withValues(alpha: 0.35)
          : cs.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onHide,
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
                      item.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: 0.78),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      time,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
