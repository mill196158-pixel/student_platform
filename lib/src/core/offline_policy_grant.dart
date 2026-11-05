import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Identity claims used only to match a previously verified local grant.
/// Parsing these claims does not verify a JWT signature or authorize access.
class OfflineSessionBinding {
  const OfflineSessionBinding(
      {required this.issuer,
      required this.userId,
      required this.sessionId,
      required this.notBefore,
      required this.expiresAt});
  final String issuer;
  final String userId;
  final String sessionId;
  final DateTime notBefore;
  final DateTime expiresAt;

  static OfflineSessionBinding? fromSession(
      Session session, String expectedIssuer) {
    try {
      final parts = session.accessToken.split('.');
      if (parts.length != 3 || parts.any((p) => p.isEmpty)) return null;
      final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (claims is! Map<String, dynamic>) return null;
      final issuer = claims['iss'];
      final sub = claims['sub'];
      final sid = claims['session_id'];
      final exp = claims['exp'];
      final iat = claims['iat'];
      final nbf = claims['nbf'];
      final aud = claims['aud'];
      final audienceMatches = aud == 'authenticated' ||
          (aud is List &&
              aud.every((e) => e is String) &&
              aud.contains('authenticated'));
      if (expectedIssuer.isEmpty ||
          issuer != expectedIssuer ||
          sub is! String ||
          sub != session.user.id ||
          sub.isEmpty ||
          sid is! String ||
          !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
              .hasMatch(sid) ||
          !audienceMatches ||
          claims['role'] != 'authenticated' ||
          iat is! int ||
          iat <= 0 ||
          (nbf != null && (nbf is! int || nbf <= 0)) ||
          exp is! int ||
          exp <= iat ||
          (nbf is int && nbf >= exp)) return null;
      return OfflineSessionBinding(
          issuer: issuer as String,
          userId: sub,
          sessionId: sid,
          notBefore: DateTime.fromMillisecondsSinceEpoch(
              (nbf is int && nbf > iat ? nbf : iat) * 1000,
              isUtc: true),
          expiresAt:
              DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true));
    } catch (_) {
      return null;
    }
  }
}

/// A record of a successful live policy check. This class does not persist it,
/// validate a server policy, or grant a capability.
class OfflinePolicyGrant {
  static const maximumLifetime = Duration(hours: 24);
  const OfflinePolicyGrant(
      {required this.issuer,
      required this.userId,
      required this.sessionId,
      required this.checkedAt,
      required this.validUntil});
  final String issuer;
  final String userId;
  final String sessionId;
  final DateTime checkedAt;
  final DateTime validUntil;

  Map<String, Object> toJson() => {
        'schema': 1,
        'issuer': issuer,
        'uid': userId,
        'sid': sessionId,
        'checked_at': checkedAt.toUtc().toIso8601String(),
        'valid_until': validUntil.toUtc().toIso8601String()
      };

  static OfflinePolicyGrant? fromJson(Object? raw) {
    if (raw is! Map || raw['schema'] != 1) return null;
    final issuer = raw['issuer'], uid = raw['uid'], sid = raw['sid'];
    final checked = raw['checked_at'], until = raw['valid_until'];
    if (issuer is! String ||
        issuer.isEmpty ||
        uid is! String ||
        uid.isEmpty ||
        sid is! String ||
        sid.isEmpty ||
        checked is! String ||
        until is! String) return null;
    final checkedAt = DateTime.tryParse(checked)?.toUtc();
    final validUntil = DateTime.tryParse(until)?.toUtc();
    if (checkedAt == null ||
        validUntil == null ||
        checkedAt.toIso8601String() != checked ||
        validUntil.toIso8601String() != until ||
        !validUntil.isAfter(checkedAt) ||
        validUntil.difference(checkedAt) > maximumLifetime) return null;
    return OfflinePolicyGrant(
        issuer: issuer,
        userId: uid,
        sessionId: sid,
        checkedAt: checkedAt,
        validUntil: validUntil);
  }

  /// This checks record consistency only; true is not authorization. The JWT
  /// is not verified here. Explicit denial or unknown errors must pass false.
  bool matchesForCachedRead(OfflineSessionBinding? binding,
      {required DateTime now, required bool policyTransportFailure}) {
    final time = now.toUtc();
    return policyTransportFailure &&
        binding != null &&
        issuer == binding.issuer &&
        userId == binding.userId &&
        sessionId == binding.sessionId &&
        validUntil.isAfter(checkedAt) &&
        validUntil.difference(checkedAt) <= maximumLifetime &&
        !time.isBefore(binding.notBefore) &&
        !time.isBefore(checkedAt) &&
        time.isBefore(validUntil) &&
        time.isBefore(binding.expiresAt);
  }
}
