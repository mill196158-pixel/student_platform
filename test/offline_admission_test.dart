import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/offline_admission.dart';

void main() {
  final now = DateTime.utc(2026, 11, 5, 12);
  final future = now.add(const Duration(minutes: 10));

  test('requires an identity, transport failure and unexpired token', () {
    final admission = OfflineAdmission();
    expect(admission.beginPolicyCheck(), isNull);
    admission.replaceIdentity('user-a');
    final attempt = admission.beginPolicyCheck()!;
    expect(admission.permits('user-a', now), isFalse);
    expect(
        admission.admitAfterTransportFailure(attempt,
            sessionExpiresAt: null, now: now),
        isFalse);
    expect(
        admission.admitAfterTransportFailure(attempt,
            sessionExpiresAt: now, now: now),
        isFalse);
    expect(
        admission.admitAfterTransportFailure(attempt,
            sessionExpiresAt: future, now: now),
        isTrue);
    expect(admission.permits('user-a', now), isTrue);
    expect(admission.permits('user-b', now), isFalse);
    expect(admission.permits('user-a', future), isFalse);
  });

  test('late response cannot authorize another or a renewed same-user session',
      () {
    final admission = OfflineAdmission()..replaceIdentity('user-a');
    final oldAttempt = admission.beginPolicyCheck()!;
    admission.replaceIdentity(null);
    admission.replaceIdentity('user-a');
    expect(
        admission.admitAfterTransportFailure(oldAttempt,
            sessionExpiresAt: future, now: now),
        isFalse);
    final freshAttempt = admission.beginPolicyCheck()!;
    expect(
        admission.admitAfterTransportFailure(freshAttempt,
            sessionExpiresAt: future, now: now),
        isTrue);
    admission.replaceIdentity('user-b');
    expect(admission.permits('user-a', now), isFalse);
    expect(admission.permits('user-b', now), isFalse);
  });

  test('explicit revocation prevents reuse of an admission', () {
    final admission = OfflineAdmission()..replaceIdentity('user-a');
    final attempt = admission.beginPolicyCheck()!;
    admission.admitAfterTransportFailure(attempt,
        sessionExpiresAt: future, now: now);
    admission.revoke();
    expect(admission.permits('user-a', now), isFalse);
    expect(
        admission.admitAfterTransportFailure(attempt,
            sessionExpiresAt: future, now: now),
        isFalse);
  });

  test('an older failure cannot override a newer policy check', () {
    final admission = OfflineAdmission()..replaceIdentity('user-a');
    final older = admission.beginPolicyCheck()!;
    final newer = admission.beginPolicyCheck()!;
    expect(
        admission.admitAfterTransportFailure(older,
            sessionExpiresAt: future, now: now),
        isFalse);
    expect(
        admission.admitAfterTransportFailure(newer,
            sessionExpiresAt: future, now: now),
        isTrue);
  });

  test('a controller rejects an attempt issued by another controller', () {
    final a = OfflineAdmission()..replaceIdentity('user-a');
    final b = OfflineAdmission()..replaceIdentity('user-a');
    final foreign = a.beginPolicyCheck()!;
    b.beginPolicyCheck();
    expect(
        b.admitAfterTransportFailure(foreign,
            sessionExpiresAt: future, now: now),
        isFalse);
  });
}
