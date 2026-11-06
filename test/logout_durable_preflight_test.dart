import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';

void main() {
  test('no cleanup or signout starts before the durable revoke commits',
      () async {
    final gate = Completer<bool>();
    final calls = <String>[];
    final result = runLogoutCleanup(
      memoryFence: () => calls.add('memory-fence'),
      durableRevoke: () {
        calls.add('fence');
        return gate.future;
      },
      cleanups: [() async => calls.add('cleanup')],
      signOut: () async => calls.add('signout'),
      clearSession: () => calls.add('clear'),
    );
    expect(calls, ['memory-fence', 'fence']);
    gate.complete(true);
    expect(await result, LogoutCleanupResult.signedOut);
    expect(calls, ['memory-fence', 'fence', 'cleanup', 'signout', 'clear']);
  });

  for (final throws in [false, true]) {
    test('failed durable revoke leaves logout and data untouched ($throws)',
        () async {
      final calls = <String>[];
      final result = await runLogoutCleanup(
        memoryFence: () => calls.add('memory-fence'),
        durableRevoke: () async {
          calls.add('fence');
          if (throws) throw StateError('disk');
          return false;
        },
        cleanups: [() async => calls.add('cleanup')],
        signOut: () async => calls.add('signout'),
        clearSession: () => calls.add('clear'),
      );
      expect(result, LogoutCleanupResult.blockedBeforeSignOut);
      expect(calls, ['memory-fence', 'fence']);
    });
  }

  for (final failedStep in [0, 1, 2]) {
    test('synchronous fence step $failedStep blocks signout on error',
        () async {
      final calls = <String>[];
      final outcome = await runLogoutCleanup(
        memoryFence: () {
          for (var step = 0; step < 3; step++) {
            calls.add('fence-$step');
            if (step == failedStep) throw StateError('fence');
          }
        },
        cleanups: [() async => calls.add('cleanup')],
        signOut: () async => calls.add('signout'),
        clearSession: () => calls.add('clear'),
      );
      expect(outcome, LogoutCleanupResult.blockedBeforeSignOut);
      expect(calls, [for (var i = 0; i <= failedStep; i++) 'fence-$i']);
    });
  }

  test('a later cleanup failure waits for the earlier delayed cleanup',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    var signedOut = false;
    final result = runLogoutCleanup(
      memoryFence: () {},
      durableRevoke: () async => true,
      cleanups: [
        () async {
          started.complete();
          await gate.future;
        },
        () async => throw StateError('cleanup failed'),
      ],
      signOut: () async {
        signedOut = true;
      },
      clearSession: () {},
    );
    await started.future;
    expect(signedOut, isFalse);
    gate.complete();
    expect(await result, LogoutCleanupResult.signedOutCleanupIncomplete);
    expect(signedOut, isTrue);
  });

  test('failure to fence memory stops before touching durable state', () async {
    var durableCalled = false;
    final outcome = await runLogoutCleanup(
      memoryFence: () => throw StateError('fence'),
      durableRevoke: () async {
        durableCalled = true;
        return true;
      },
      cleanups: [],
      signOut: () async => fail('must not sign out'),
      clearSession: () => fail('must not clear'),
    );
    expect(outcome, LogoutCleanupResult.blockedBeforeSignOut);
    expect(durableCalled, isFalse);
  });

  test('all memory fences run even when an earlier listener throws', () async {
    final calls = <int>[];
    final outcome = await runLogoutCleanup(
      memoryFence: () => runLogoutMemoryFences([
        () {
          calls.add(1);
          throw StateError('listener');
        },
        () => calls.add(2),
        () => calls.add(3),
      ]),
      durableRevoke: () async => fail('must not start durable revoke'),
      cleanups: [],
      signOut: () async => fail('must not sign out'),
      clearSession: () => fail('must not clear'),
    );
    expect(calls, [1, 2, 3]);
    expect(outcome, LogoutCleanupResult.blockedBeforeSignOut);
  });

  test('successful signout with failed local clear is incomplete', () async {
    final outcome = await runLogoutCleanup(
      cleanups: [],
      signOut: () async {},
      clearSession: () => throw StateError('clear'),
    );
    expect(outcome, LogoutCleanupResult.signedOutCleanupIncomplete);
  });

  test('old logout stops before next cleanup and signout after A changes to B',
      () async {
    var currentOwner = 'a';
    final started = Completer<void>();
    final resume = Completer<void>();
    final calls = <String>[];
    final pending = runLogoutCleanup(
      memoryFence: () {},
      isOwnerCurrent: () => currentOwner == 'a',
      mayClearSession: () => currentOwner == 'a',
      cleanups: [
        () async {
          started.complete();
          await resume.future;
        },
        () async => calls.add('second-cleanup'),
      ],
      signOut: () async => calls.add('signout'),
      clearSession: () => calls.add('clear'),
    );
    await started.future;
    currentOwner = 'b';
    resume.complete();
    expect(await pending, LogoutCleanupResult.ownerChanged);
    expect(calls, isEmpty);
  });
}
