import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/utils/safe_debug_log.dart';

/// Resolves what others should see for a user's status.
///
/// Offline if [lastSeenAt] is missing or older than [offlineAfter],
/// otherwise the user's chosen [status] (fallback «Онлайн»).
class UserStatusDisplay {
  UserStatusDisplay._();

  static const String offlineLabel = 'Не в сети';
  static const Duration offlineAfter = Duration(minutes: 3);

  static bool isOnline(DateTime? lastSeenAt, {DateTime? now}) {
    if (lastSeenAt == null) return false;
    final t = now ?? DateTime.now().toUtc();
    final seen = lastSeenAt.toUtc();
    return t.difference(seen) <= offlineAfter;
  }

  static String resolve({
    String? status,
    DateTime? lastSeenAt,
    DateTime? now,
  }) {
    if (!isOnline(lastSeenAt, now: now)) return offlineLabel;
    final s = (status ?? '').trim();
    if (s.isEmpty || s == offlineLabel) return 'Онлайн';
    return s;
  }

  static DateTime? parseLastSeen(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw.toUtc();
    return DateTime.tryParse(raw.toString())?.toUtc();
  }
}

/// Heartbeats [users.last_seen_at] while the app is in foreground.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  static const Duration _interval = Duration(seconds: 45);

  Timer? _timer;
  bool _started = false;
  bool _observerAttached = false;
  bool _touching = false;

  void start() {
    if (_started) {
      unawaited(touch());
      return;
    }
    _started = true;
    if (!_observerAttached) {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    }
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => unawaited(touch()));
    unawaited(touch());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(touch());
      _timer?.cancel();
      _timer = Timer.periodic(_interval, (_) => unawaited(touch()));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> touch() async {
    if (_touching) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) return;
    _touching = true;
    try {
      await Supabase.instance.client.rpc('touch_my_presence');
    } catch (e) {
      safeDebugLog('[Presence] touch failed: ${e.runtimeType}');
    } finally {
      _touching = false;
    }
  }
}
