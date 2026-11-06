import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/online_side_effect_barrier.dart';
import 'guarded_push_target.dart';
import 'push_payload.dart';

/// Experimental, neutral fallback. A current summary proves present access,
/// not the recipient of the original push. The route has no data operations.
Future<void> openGuardedPushHint({
  required NavigatorState navigator,
  required PushPayload payload,
  required OnlineSideEffectBarrier barrier,
  required bool Function() isCurrent,
  required Future<dynamic> Function() fetchSummaries,
  Widget Function(PushPayload)? buildVerifiedTarget,
}) async {
  bool allowed() {
    try {
      return navigator.mounted && barrier.isOpen && isCurrent();
    } catch (_) {
      return false;
    }
  }

  if (!allowed()) return;
  final target = await resolveCurrentPushTarget(
      payload: payload,
      barrier: barrier,
      isCurrent: allowed,
      fetchSummaries: fetchSummaries);
  if (target == null || !allowed()) return;
  final route = MaterialPageRoute<void>(
      builder: (_) => buildVerifiedTarget?.call(target) ?? const Scaffold(
            body: SafeArea(
                child: Center(
                    child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Чтобы открыть чат, перейдите в раздел «Сообщения».',
                  textAlign: TextAlign.center),
            ))),
          ));
  final popped = navigator.push(route);
  final removeClose = barrier.onClose(() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    });
    WidgetsBinding.instance.scheduleFrame();
  });
  unawaited(popped.whenComplete(removeClose));
}
