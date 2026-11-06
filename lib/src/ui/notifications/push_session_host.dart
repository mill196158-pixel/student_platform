import 'dart:async';
import 'package:student_platform/src/services/push/system_notification_sync.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/services/push/push_payload.dart';

/// Starts push after auth and flushes pending deep links once the shell is ready.
class PushSessionHost extends StatefulWidget {
  const PushSessionHost({super.key, required this.child, this.barrier,
    this.debugStart, this.debugReconcile, this.debugAuthenticated,
    this.debugFlush, this.debugCurrentUser, this.debugSubscribe});

  final Widget child;
  final OnlineSideEffectBarrier? barrier;
  @visibleForTesting
  final Future<void> Function()? debugStart;
  @visibleForTesting
  final Future<void> Function()? debugReconcile;
  @visibleForTesting
  final Future<void> Function()? debugAuthenticated;
  @visibleForTesting
  final Future<void> Function()? debugFlush;
  @visibleForTesting
  final String? Function()? debugCurrentUser;
  @visibleForTesting
  final void Function(void Function(PostgresChangePayload))? debugSubscribe;

  @override
  State<PushSessionHost> createState() => _PushSessionHostState();
}

class _PushSessionHostState extends State<PushSessionHost>
    with WidgetsBindingObserver {
  bool _started = false;
  StreamSubscription<InAppNotificationEvent>? _badgeSubscription;
  late final SystemNotificationSync _systemNotifications;

  RealtimeChannel? _notificationChannel;
  int _channelRevision = 0;
  VoidCallback? _removeCloseHook;

  void _bindCloseHook(OnlineSideEffectBarrier? barrier) {
    _removeCloseHook?.call();
    _removeCloseHook = barrier?.onClose(() => _teardownGuarded(barrier));
  }

  void _teardownGuarded(OnlineSideEffectBarrier barrier) {
    _channelRevision++;
    _systemNotifications.invalidate();
    PushNotificationService.instance.closeGuardedSession(barrier);
    final channel = _notificationChannel;
    _notificationChannel = null;
    if (channel != null) {
      unawaited(barrier.trackTeardown(() async {
        await Supabase.instance.client.removeChannel(channel);
      }));
    }
  }

  bool get _allowed => mounted && (widget.barrier?.isOpen ?? true);
  bool _currentBarrier(OnlineSideEffectBarrier? captured) =>
      mounted && identical(widget.barrier, captured) && (captured?.isOpen ?? true);
  Future<void> _reconcile() {
    final captured = widget.barrier;
    return widget.debugReconcile?.call() ?? _systemNotifications.reconcile(
        isCurrent: captured == null ? null : () => _currentBarrier(captured));
  }
  Future<void> _startOperation() => widget.debugStart?.call() ?? _start();

  Future<void> _dispatch(Future<void> Function() operation) async {
    if (!_allowed) return;
    final barrier = widget.barrier;
    if (barrier == null) {
      await operation();
    } else {
      await barrier.run(operation);
    }
  }

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
    _bindCloseHook(widget.barrier);
    _badgeSubscription = InAppNotificationBus.instance.stream.listen((event) {
      // The legacy bus has no owner/session provenance. Guarded sessions must
      // not process events which may have been queued by a previous owner.
      if (widget.barrier != null) return;
      if (event.type == '_badge_refresh') {
        unawaited(_dispatch(_reconcile));
      } else {
        _systemNotifications.invalidate();
      }
    });
    unawaited(_dispatch(_reconcile));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_dispatch(_startOperation)));
  }

  Future<void> _start() async {
    if (!_allowed || _started) return;
    final startingBarrier = widget.barrier;
    bool current() => _currentBarrier(startingBarrier);
    final user = widget.debugCurrentUser != null
        ? widget.debugCurrentUser!()
        : Supabase.instance.client.auth.currentUser?.id;
    if (user == null) return;
    _started = true;

    if (widget.debugAuthenticated == null || widget.debugSubscribe != null) {
      _subscribeNotificationRealtime();
    }
    try {
      if (widget.debugAuthenticated != null) {
        await widget.debugAuthenticated!();
      } else {
        await PushNotificationService.instance.onAuthenticated(context,
            barrier: startingBarrier,
            isCurrent: startingBarrier == null ? null : current);
      }
      if (!current()) return;
      if (widget.debugAuthenticated == null &&
          PushNotificationService.instance.isSupportedPlatform &&
          !PushNotificationService.instance.isFirebaseReady) {
        _started =
            false; // A handled Firebase failure must still retry on resume.
        return;
      }
      if (widget.debugFlush != null) {
        await widget.debugFlush!();
      } else if (startingBarrier != null) {
        await PushNotificationService.instance.flushGuardedPending(startingBarrier);
      } else if (startingBarrier == null) {
        // The legacy pending queue does not carry a session binding.
        await PushNavigation.flushPending(context);
      }
    } catch (_) {
      if (current()) _started = false; // Retry after transient failure.
    }
  }

  void _subscribeNotificationRealtime() {
    final uid = widget.debugCurrentUser != null
        ? widget.debugCurrentUser!() : Supabase.instance.client.auth.currentUser?.id;
    if (!_allowed || uid == null || uid.isEmpty || _notificationChannel != null) return;
    final capturedBarrier = widget.barrier;
    final revision = ++_channelRevision;

    void handle(PostgresChangePayload payload) {
            final currentUser = widget.debugCurrentUser != null
                ? widget.debugCurrentUser!() : Supabase.instance.client.auth.currentUser?.id;
            if (!_currentBarrier(capturedBarrier) || revision != _channelRevision ||
                currentUser != uid) return;
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
    }
    if (widget.debugSubscribe != null) {
      widget.debugSubscribe!(handle);
      return;
    }
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
          callback: handle,
        )
        .subscribe();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_dispatch(_startOperation));
      unawaited(_dispatch(_reconcile));
    }
  }

  @override
  void didUpdateWidget(covariant PushSessionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.barrier, widget.barrier)) {
      final oldBarrier = oldWidget.barrier;
      if (oldBarrier == null) {
        _channelRevision++;
        _systemNotifications.invalidate();
        final oldChannel = _notificationChannel;
        _notificationChannel = null;
        if (oldChannel != null) unawaited(Supabase.instance.client.removeChannel(oldChannel));
      }
      oldBarrier?.close();
      _bindCloseHook(widget.barrier);
      _started = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_allowed) {
          unawaited(_dispatch(_startOperation));
          unawaited(_dispatch(_reconcile));
        }
      });
    }
  }

  @override
  void dispose() {
    final barrier = widget.barrier;
    barrier?.close();
    _removeCloseHook?.call();
    _channelRevision++;
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
