import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';

void main() {
  test('stale reserved owner cannot start push logout for a newer account', () async {
    var owner = 'a';
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => owner == 'a');
    final reservation = PushLogoutReservation.forTesting(barrier,
        isOwnerCurrent: () => owner == 'a');
    barrier.close();
    owner = 'b';
    // No Supabase instance exists: a stale operation must return before any
    // current-session lookup or notification/token side effect.
    await PushNotificationService.instance.onLogout(reservation: reservation);
    reservation.finish();
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
  });
  test('logout reserves drain before fencing and cannot sign out new owner', () async {
    var owner = 'a', signedOut = false;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => owner == 'a');
    final pending = Completer<void>();
    PushLogoutReservation? reservation;
    final work = runLogoutCleanup(
      isOwnerCurrent: () => owner == 'a',
      memoryFence: () { reservation = PushLogoutReservation.forTesting(barrier); barrier.close(); },
      durableRevoke: () async => true,
      cleanups: [() async { try { await pending.future; } finally { reservation?.finish(); } }],
      signOut: () async { signedOut = true; }, clearSession: () {});
    await Future<void>.delayed(Duration.zero);
    expect(await barrier.closeAndDrain(timeout: const Duration(milliseconds: 5)), isFalse);
    owner = 'b';
    pending.complete();
    expect(await work, LogoutCleanupResult.ownerChanged);
    expect(signedOut, isFalse);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), isTrue);
  });
}
