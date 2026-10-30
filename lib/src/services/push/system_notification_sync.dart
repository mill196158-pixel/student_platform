import 'package:flutter/services.dart';

/// Clear OS notifications only after an authoritative, successful unread query.
/// A failed request must never be interpreted as zero unread notifications.
class SystemNotificationSync {
  SystemNotificationSync({
    required this.currentUser,
    required this.unreadCount,
    Future<void> Function()? clear,
  }) : clear = clear ?? _clearAndroid;

  final String? Function() currentUser;
  final Future<int> Function() unreadCount;
  final Future<void> Function() clear;
  int _generation = 0;

  static Future<void> _clearAndroid() async {
    try {
      await const MethodChannel('student_platform/notifications')
          .invokeMethod<void>('clearNotifications');
    } on MissingPluginException {
      // Non-Android clients do not implement this channel.
    }
  }

  void invalidate() => _generation++;

  Future<void> reconcile() async {
    final user = currentUser();
    if (user == null) return;
    final generation = ++_generation;
    try {
      final count = await unreadCount();
      if (count == 0 && generation == _generation && currentUser() == user) {
        await clear();
      }
    } catch (_) {
      // Preserve existing notifications on network/platform failure.
    }
  }
}
