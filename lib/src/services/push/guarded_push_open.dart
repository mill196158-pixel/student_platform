import '../../core/online_side_effect_barrier.dart';

/// Tracks owner verification and navigation as one online operation.
Future<void> openVerifiedPush(
    {required OnlineSideEffectBarrier barrier,
    required bool Function() isCurrent,
    required Future<bool> Function() verify,
    required Future<void> Function() open}) async {
  bool allowed() {
    try {
      return barrier.isOpen && isCurrent();
    } catch (_) {
      return false;
    }
  }

  if (!allowed()) return;
  await barrier.run(() async {
    if (!allowed() || !await verify() || !allowed()) return;
    await open();
  });
}
