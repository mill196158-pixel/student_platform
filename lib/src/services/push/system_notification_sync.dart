import 'package:flutter/services.dart';

typedef DeliveredNotification = ({String tag, int id});

/// Reconciles a snapshot of the Android notification drawer. Capturing it before
/// querying the server protects deliveries that arrive during that request.
class SystemNotificationSync {
  SystemNotificationSync({
    required this.currentUser,
    required this.unreadCount,
    required this.lookupRead,
    this.listDelivered = _listAndroid,
    this.cancelDelivered = _cancelAndroid,
  });

  final String? Function() currentUser;
  final Future<int> Function() unreadCount;
  final Future<Set<String>> Function(String owner, Set<String> ids) lookupRead;
  final Future<List<DeliveredNotification>> Function() listDelivered;
  final Future<void> Function(List<DeliveredNotification>) cancelDelivered;
  static const _channel = MethodChannel('student_platform/notifications');
  static final _uuid =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _legacyTag = RegExp(r'^FCM-Notification:[0-9]+$');
  int _generation = 0;

  static Future<List<DeliveredNotification>> _listAndroid() async {
    try {
      final rows = await _channel
          .invokeListMethod<Object?>('listDeliveredNotifications');
      return [
        for (final row in rows ?? const [])
          if (row case {'id': int id, 'tag': String tag}) (tag: tag, id: id),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<void> _cancelAndroid(List<DeliveredNotification> alerts) =>
      _channel.invokeMethod<void>('cancelDeliveredNotifications', [
        for (final alert in alerts) {'tag': alert.tag, 'id': alert.id}
      ]);

  String? _notificationId(String tag, String owner) {
    final prefix = 'student:$owner:';
    if (!_uuid.hasMatch(owner) || !tag.startsWith(prefix)) return null;
    final id = tag.substring(prefix.length);
    return _uuid.hasMatch(id) ? id : null;
  }

  void invalidate() => _generation++;

  /// An acknowledged read/hide is final for this row. Other concurrent
  /// arrivals must not invalidate it, including a second chat read.
  Future<void> dismissRead(String owner, Set<String> ids,
      {required bool Function() isCurrent}) async {
    bool valid() => currentUser() == owner && isCurrent();
    try {
      if (!_uuid.hasMatch(owner) || !valid()) return;
      // FCM uses id 0 with the server-provided tag. Persist the acknowledgement
      // even if its visible delivery has not yet reached the drawer.
      final read = [
        for (final id in ids)
          if (_uuid.hasMatch(id)) (tag: 'student:$owner:$id', id: 0),
      ];
      if (read.isNotEmpty) await cancelDelivered(read);
    } catch (_) {
      // Reconciliation will retry on resume.
    }
  }

  Future<void> reconcile({bool Function()? isCurrent}) async {
    final generation = ++_generation;
    final owner = currentUser();
    bool valid() =>
        generation == _generation &&
        currentUser() == owner &&
        (isCurrent?.call() ?? true);
    try {
      if (owner == null || !valid()) return;
      final snapshot = await listDelivered();
      if (!valid()) return;
      final owned = <DeliveredNotification, String>{};
      final legacy = <DeliveredNotification>[];
      for (final alert in snapshot) {
        final id = _notificationId(alert.tag, owner);
        if (id != null) {
          owned[alert] = id;
        } else if (_legacyTag.hasMatch(alert.tag)) {
          legacy.add(alert);
        }
      }
      if (owned.isEmpty && legacy.isEmpty) return;
      final count = await unreadCount();
      if (!valid() || count < 0) return;
      final remove = <DeliveredNotification>[];
      if (count == 0) {
        remove.addAll([...owned.keys, ...legacy]);
      } else if (owned.isNotEmpty) {
        final read = await lookupRead(owner, owned.values.toSet());
        remove.addAll(owned.keys.where((alert) => read.contains(owned[alert])));
      }
      if (remove.isNotEmpty && valid()) await cancelDelivered(remove);
    } catch (_) {
      // Preserve existing notifications on network/platform failure.
    }
  }
}
