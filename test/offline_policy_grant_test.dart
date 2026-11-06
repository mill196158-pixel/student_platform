import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  const issuer = 'https://project.example/auth/v1';
  const sid = '12345678-1234-1234-1234-123456789012';
  final now = DateTime.utc(2026, 11, 5, 12);
  Map<String, dynamic> claims() => {
        'iss': issuer,
        'sub': 'a',
        'session_id': sid,
        'role': 'authenticated',
        'aud': 'authenticated',
        'iat':
            now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
                1000,
        'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      };
  OfflineSessionBinding? bind(Map<String, dynamic> data, {String uid = 'a'}) {
    final payload =
        base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
    return OfflineSessionBinding.fromSession(
        fakeSession(uid, access: 'e30.$payload.signature'), issuer);
  }

  final grant = OfflinePolicyGrant(
      issuer: issuer,
      userId: 'a',
      sessionId: sid,
      checkedAt: now.subtract(const Duration(minutes: 1)),
      validUntil: now.add(const Duration(minutes: 30)));

  test('requires matching session, unexpired grant and transport failure', () {
    final binding = bind(claims());
    expect(binding, isNotNull);
    expect(
        grant.matchesForCachedRead(binding,
            now: now, policyTransportFailure: true),
        isTrue);
    expect(
        grant.matchesForCachedRead(binding,
            now: now, policyTransportFailure: false),
        isFalse);
    expect(
        grant.matchesForCachedRead(binding,
            now: grant.validUntil, policyTransportFailure: true),
        isFalse);
    expect(
        grant.matchesForCachedRead(binding,
            now: grant.checkedAt.subtract(const Duration(seconds: 1)),
            policyTransportFailure: true),
        isFalse);
    final other = claims()
      ..['session_id'] = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    expect(
        grant.matchesForCachedRead(bind(other),
            now: now, policyTransportFailure: true),
        isFalse);
    final expired = claims()..['exp'] = now.millisecondsSinceEpoch ~/ 1000;
    expect(
        grant.matchesForCachedRead(bind(expired),
            now: now, policyTransportFailure: true),
        isFalse);
    final future = claims()
      ..['iat'] =
          now.add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;
    expect(
        grant.matchesForCachedRead(bind(future),
            now: now, policyTransportFailure: true),
        isFalse);
    final futureNbf = claims()
      ..['nbf'] =
          now.add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;
    expect(
        grant.matchesForCachedRead(bind(futureNbf),
            now: now, policyTransportFailure: true),
        isFalse);
  });

  test('local snapshots can outlive token only within a bounded owner grant',
      () {
    final binding = bind(claims())!;
    final localGrant = OfflinePolicyGrant(
        issuer: issuer,
        userId: 'a',
        sessionId: sid,
        checkedAt: now,
        validUntil: now.add(const Duration(days: 30)));
    final later = now.add(const Duration(hours: 2));
    expect(localGrant.matchesForLocalSnapshot(binding, now: later), isTrue);
    expect(
        localGrant.matchesForCachedRead(binding,
            now: later, policyTransportFailure: true),
        isFalse);
    expect(
        localGrant.matchesForLocalSnapshot(binding, now: localGrant.validUntil),
        isFalse);
    expect(OfflinePolicyGrant.fromJson(localGrant.toJson()), isNull);
    expect(
        OfflinePolicyGrant.fromJson(localGrant.toJson(),
            maximumAge: OfflinePolicyGrant.maximumLocalSnapshotLifetime),
        isNotNull);
    final otherSession = claims()
      ..['session_id'] = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    expect(localGrant.matchesForLocalSnapshot(bind(otherSession), now: later),
        isFalse);
    final afterToken = OfflinePolicyGrant(
        issuer: issuer,
        userId: 'a',
        sessionId: sid,
        checkedAt: now.add(const Duration(hours: 2)),
        validUntil: now.add(const Duration(days: 1)));
    expect(afterToken.matchesForLocalSnapshot(binding, now: later), isFalse);
  });
  test('rejects missing, malformed or foreign JWT claims', () {
    for (final changed in [
      claims()..remove('exp'),
      claims()..['exp'] = '123',
      claims()..['iss'] = 'other',
      claims()..['sub'] = 'b',
      claims()..['session_id'] = 'not-a-uuid',
      claims()..['role'] = 'anon',
      claims()..['aud'] = 'anon',
      claims()..remove('iat'),
      claims()..['nbf'] = 'bad',
      claims()..['aud'] = ['authenticated', 123],
    ]) {
      expect(bind(changed), isNull);
    }
  });
  test('token rotation with the same session id does not extend grant expiry',
      () {
    final rotated = claims()
      ..['iat'] = now.millisecondsSinceEpoch ~/ 1000
      ..['exp'] =
          now.add(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000;
    final binding = bind(rotated);
    expect(
        grant.matchesForCachedRead(binding,
            now: now, policyTransportFailure: true),
        isTrue);
    expect(
        grant.matchesForCachedRead(binding,
            now: grant.validUntil, policyTransportFailure: true),
        isFalse);
  });
  test('codec rejects malformed grants and retains fixed expiry', () {
    final restored = OfflinePolicyGrant.fromJson(grant.toJson())!;
    expect(restored.validUntil, grant.validUntil);
    expect(
        restored.matchesForCachedRead(bind(claims()),
            now: now, policyTransportFailure: true),
        isTrue);
    expect(OfflinePolicyGrant.fromJson({'schema': 1}), isNull);
    expect(
        OfflinePolicyGrant.fromJson({...grant.toJson(), 'schema': 2}), isNull);
    expect(
        OfflinePolicyGrant.fromJson(
            {...grant.toJson(), 'valid_until': 'invalid'}),
        isNull);
    expect(
        OfflinePolicyGrant.fromJson({
          ...grant.toJson(),
          'valid_until': now.add(const Duration(days: 7)).toIso8601String()
        }),
        isNull);
    expect(
        OfflinePolicyGrant.fromJson(
            {...grant.toJson(), 'checked_at': '2026-11-31T00:00:00.000Z'}),
        isNull);
    expect(
        OfflinePolicyGrant.fromJson(
            {...grant.toJson(), 'checked_at': '2026-11-05T11:00:00.000'}),
        isNull);
  });
}
