import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/session_capabilities.dart';
import '../../core/session_capabilities_host.dart';

({Object session, bool Function() current})? captureChatReadOwner(
    BuildContext context) {
  final client = Supabase.instance.client;
  final session = client.auth.currentSession;
  if (session == null) return null;
  final caps = SessionCapabilitiesHost.maybeRead(context);
  final permit = caps?.capture(SessionCapability.mutation);
  bool current() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      identical(client.auth.currentSession, session) &&
      (caps == null ||
          permit != null && caps.permits(permit, SessionCapability.mutation));
  return current() ? (session: session, current: current) : null;
}

/// Tracks the two writes separately so a failed notification update can be
/// retried without moving the server chat cursor twice.
class ChatReadProgress {
  ChatReadProgress({this.retryDelay = const Duration(seconds: 1)});
  final Duration retryDelay;
  (Object, String)? _cursor;
  (Object, String)? _synced;
  (Object, String)? _latest;
  final _inFlight = <(Object, String), Future<void>>{};
  Future<void> _tail = Future.value();

  Future<void> mark({
    required Object scope,
    required String messageId,
    required bool Function() current,
    required Future<void> Function() markCursor,
    required Future<void> Function() syncNotifications,
  }) {
    final key = (scope, messageId);
    if (!current() || _synced == key) return Future.value();
    _latest = key;
    final running = _inFlight[key];
    if (running != null) return running;
    bool valid() => _latest == key && current();
    final work = _tail.then((_) async {
      if (!valid()) return;
      if (_cursor != key) {
        await markCursor();
        if (!current()) return;
        _cursor = key;
      }
      if (!valid()) return;
      try {
        await syncNotifications();
      } catch (_) {
        if (!valid()) return;
        await Future<void>.delayed(retryDelay);
        if (!valid()) return;
        await syncNotifications();
      }
      if (valid()) _synced = key;
    }).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = work;
    // One failed read must not poison subsequent scroll or resume events.
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return work;
  }
}
