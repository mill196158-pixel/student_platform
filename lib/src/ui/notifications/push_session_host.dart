import 'dart:async';
import 'package:student_platform/src/services/push/system_notification_sync.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/services/push/push_payload.dart';

/// Starts push after auth and flushes pending deep links once the shell is ready.
class PushSessionHost extends StatefulWidget {
  const PushSessionHost({super.key, required this.child});

  final Widget child;

  @override
  State<PushSessionHost> createState() => _PushSessionHostState();
}

class _PushSessionHostState extends State<PushSessionHost>
    with WidgetsBindingObserver {
  bool _started = false;
  StreamSubscription<InAppNotificationEvent>? _badgeSubscription;
  late final SystemNotificationSync _systemNotifications;

  RealtimeChannel? _notificationChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _systemNotifications = SystemNotificationSync(
      currentUser: () => Supabase.instance.client.auth.currentUser?.id,
      unreadCount: () async {
        final result = await Supabase.instance.client
            .rpc('get_my_unread_notification_count');
        if (result is! num) throw StateError('Invalid unread count');
        return result.toInt();
      },
    );
    _badgeSubscription = InAppNotificationBus.instance.stream.listen((event) {
      if (event.type == '_badge_refresh') {
        unawaited(_systemNotifications.reconcile());
      } else {
        _systemNotifications.invalidate();
      }
    });
    unawaited(_systemNotifications.reconcile());
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_started) return;
    if (Supabase.instance.client.auth.currentUser == null) return;
    _started = true;

    _subscribeNotificationRealtime();
    try {
      await PushNotificationService.instance.onAuthenticated(context);
      if (!mounted) return;
      await PushNavigation.flushPending(context);
    } catch (_) {
      _started = false; // Retry on resume after a transient startup failure.
    }
  }

  void _subscribeNotificationRealtime() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty || _notificationChannel != null) return;

    _notificationChannel = Supabase.instance.client
        .channel('app-notifications-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'app_notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient_id',
            value: uid,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            if (payload.eventType != PostgresChangeEvent.insert) {
              final id = (row['id'] ?? payload.oldRecord['id'])?.toString();
              if (row['read_at'] != null ||
                  row['deleted_at'] != null ||
                  payload.eventType == PostgresChangeEvent.delete) {
                if (id != null)
                  InAppNotificationBus.instance.dismissNotifications({id});
              }
              InAppNotificationBus.instance.requestBadgeRefresh();
              return;
            }
            if (row['read_at'] != null || row['deleted_at'] != null) return;
            final type = (row['event_type'] ?? '').toString();
            final title = (row['title'] ?? 'Уведомление').toString();
            final body = (row['body'] ?? '').toString();
            final data = row['data'] is Map
                ? Map<String, dynamic>.from(row['data'] as Map)
                : <String, dynamic>{};
            data.putIfAbsent('type', () => type);
            data.putIfAbsent('notification_id', () => row['id']);
            final parsed = PushPayload.tryParse(data);
            if (ActiveChatTracker.instance.isActive(parsed?.chatId)) {
              InAppNotificationBus.instance.requestBadgeRefresh();
              return;
            }

            InAppNotificationBus.instance.emit(
              InAppNotificationEvent(
                type: type,
                title: title,
                body: body,
                payload: PushNavigation.withDisplayFields(
                  parsed,
                  title: title,
                  body: body,
                ),
              ),
            );
          },
        )
        .subscribe();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
      unawaited(_systemNotifications.reconcile());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _systemNotifications.invalidate();
    unawaited(_badgeSubscription?.cancel());
    InAppNotificationBus.instance.resetSession();
    final channel = _notificationChannel;
    _notificationChannel = null;
    if (channel != null) {
      unawaited(Supabase.instance.client.removeChannel(channel));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
