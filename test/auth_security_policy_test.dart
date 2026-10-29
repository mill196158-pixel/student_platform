import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/password_policy.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';

void main() {
  test('password decision requires an authoritative boolean', () {
    expect(
        requirePasswordChangeFromRow({'must_change_password': true}), isTrue);
    expect(
        requirePasswordChangeFromRow({'must_change_password': false}), isFalse);
    for (final row in <Map<String, dynamic>?>[
      null,
      {},
      {'must_change_password': null},
      {'must_change_password': 'false'},
    ]) {
      expect(() => requirePasswordChangeFromRow(row), throwsStateError);
    }
  });

  test('anonymous direct links cannot open private routes', () async {
    for (final path in [
      '/home',
      '/profile',
      '/edit-profile',
      '/exams',
      '/my-diary',
      '/my-reviews',
      '/notification-settings',
      '/change-password'
    ]) {
      expect(
          await authRouteRedirect(
              path: path,
              hasSession: false,
              passwordChangeRequired: () async =>
                  throw StateError('must not query')),
          '/login');
    }
  });

  test('password change cannot be bypassed with a private deep link', () async {
    expect(
        await authRouteRedirect(
            path: '/profile',
            hasSession: true,
            passwordChangeRequired: () async => true),
        '/change-password');
    expect(
        await authRouteRedirect(
            path: '/home',
            hasSession: true,
            passwordChangeRequired: () async => false),
        isNull);
    expect(
        await authRouteRedirect(
            path: '/home',
            hasSession: true,
            passwordChangeRequired: () async => throw StateError('offline')),
        '/login');
  });

  test('public and password routes do not loop on a profile lookup', () async {
    for (final path in ['/login', '/splash', '/change-password']) {
      expect(
          await authRouteRedirect(
              path: path,
              hasSession: true,
              passwordChangeRequired: () async =>
                  throw StateError('must not query')),
          isNull);
    }
  });

  test('one failed cache cannot prevent other cleanups or logout', () async {
    final events = <String>[];
    final complete = await runLogoutCleanup(
        cleanups: [
          () async {
            events.add('first');
            throw StateError('disk unavailable');
          },
          () async {
            events.add('second');
          },
        ],
        signOut: () async {
          events.add('signOut');
        },
        clearSession: () {
          events.add('clear');
        });
    expect(complete, isFalse);
    expect(events, ['first', 'second', 'signOut', 'clear']);
  });

  test('session memory clears even when auth signout reports an error',
      () async {
    var cleared = false;
    await expectLater(
        runLogoutCleanup(
            cleanups: [],
            signOut: () async => throw StateError('network unavailable'),
            clearSession: () {
              cleared = true;
            }),
        throwsStateError);
    expect(cleared, isTrue);
  });
}
