import 'dart:async';

import 'package:student_platform/src/services/push/push_payload.dart';

/// Lightweight in-app event when a push/notification arrives while the app
/// is in the foreground (home, profile, etc.).
class InAppNotificationEvent {
  const InAppNotificationEvent({
    required this.type,
    required this.title,
    required this.body,
    this.payload,
  });

  final String type;
  final String title;
  final String body;
  final PushPayload? payload;

  bool get isChatMessage =>
      type == 'dm_message' || type == 'team_message' || type == 'team_reply';
}

/// App-wide bus so Home (and others) can bump the bell badge / show a snackbar
/// without depending on FCM UI alone.
class InAppNotificationBus {
  InAppNotificationBus._();
  static final InAppNotificationBus instance = InAppNotificationBus._();

  final StreamController<InAppNotificationEvent> _controller =
      StreamController<InAppNotificationEvent>.broadcast();

  Stream<InAppNotificationEvent> get stream => _controller.stream;

  void emit(InAppNotificationEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  /// Tells badge listeners to reload without showing a visual notification.
  void requestBadgeRefresh() {
    emit(
      const InAppNotificationEvent(
        type: '_badge_refresh',
        title: '',
        body: '',
      ),
    );
  }
}
