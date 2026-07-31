import 'dart:async';

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

class _PushSessionHostState extends State<PushSessionHost> {
  bool _started = false;
  RealtimeChannel? _notificationChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_started) return;
    if (Supabase.instance.client.auth.currentUser == null) return;
    _started = true;

    _subscribeNotificationRealtime();
    await PushNotificationService.instance.onAuthenticated(context);
    if (!mounted) return;
    await PushNavigation.flushPending(context);
  }

  void _subscribeNotificationRealtime() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty || _notificationChannel != null) return;

    _notificationChannel = Supabase.instance.client
        .channel('app-notifications-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'app_notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient_id',
            value: uid,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            final type = (row['event_type'] ?? '').toString();
            final title = (row['title'] ?? 'Уведомление').toString();
            final body = (row['body'] ?? '').toString();
            final data = row['data'] is Map
                ? Map<String, dynamic>.from(row['data'] as Map)
                : <String, dynamic>{};
            data.putIfAbsent('type', () => type);
            data.putIfAbsent('notification_id', () => row['id']);
            final parsed = PushPayload.tryParse(data);
            final isChatEvent = type == 'dm_message' ||
                type == 'team_message' ||
                type == 'team_reply';

            if (ActiveChatTracker.instance.isActive(parsed?.chatId) ||
                (isChatEvent &&
                    ActiveChatTracker.instance.isViewingMessages)) {
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
  void dispose() {
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
