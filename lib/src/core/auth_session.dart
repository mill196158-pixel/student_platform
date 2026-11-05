import 'package:supabase_flutter/supabase_flutter.dart';
import 'transport_failure.dart';

enum SessionRestoreStatus { restored, rejected, transportFailure, stale }

/// Keeps Supabase auth session alive: proactive refresh + restore on boot.
class AuthSession {
  AuthSession._();

  static const sessionExpiredMessage =
      'Сессия истекла. Войдите в аккаунт снова.';

  /// Refresh if missing, expired, or expiring within [refreshLeadTime].
  static Future<void> ensureFreshSession(
    SupabaseClient client, {
    Duration refreshLeadTime = const Duration(minutes: 10),
  }) async {
    final session = client.auth.currentSession;
    if (session == null) {
      await client.auth.refreshSession();
      return;
    }
    if (session.isExpired || _isExpiringSoon(session, refreshLeadTime)) {
      await client.auth.refreshSession();
    }
  }

  /// Restores a valid session from the stored refresh token (app cold start).
  static Future<bool> tryRestoreSession(SupabaseClient client) async {
    return await restoreSessionStatus(client) == SessionRestoreStatus.restored;
  }

  static Future<SessionRestoreStatus> restoreSessionStatus(
      SupabaseClient client, {Future<AuthResponse> Function()? refresh}) async {
    final initial = client.auth.currentSession;
    (String, String, String?)? identity(Session? session) => session == null
        ? null
        : (session.user.id, session.accessToken, session.refreshToken);
    final captured = identity(initial);
    try {
      final session = initial;
      if (session != null && !session.isExpired) {
        return SessionRestoreStatus.restored;
      }
      final response = await (refresh?.call() ?? client.auth.refreshSession());
      final refreshed = response.session;
      final current = identity(client.auth.currentSession);
      if (refreshed == null) {
        return current == captured
            ? SessionRestoreStatus.rejected
            : SessionRestoreStatus.stale;
      }
      if (captured == null || refreshed.isExpired || refreshed.user.id != captured.$1 ||
          identity(refreshed) != current) return SessionRestoreStatus.stale;
      return SessionRestoreStatus.restored;
    } catch (error) {
      if (identity(client.auth.currentSession) != captured) {
        return SessionRestoreStatus.stale;
      }
      if (isTemporaryTransportFailure(error)) {
        return SessionRestoreStatus.transportFailure;
      }
      return SessionRestoreStatus.rejected;
    }
  }

  static bool isAuthFailure(Object error) {
    final text = error.toString();
    return text.contains('JWT expired') ||
        text.contains('PGRST303') ||
        text.contains('401') ||
        text.contains('Unauthorized');
  }

  static bool _isExpiringSoon(Session session, Duration leadTime) {
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return true;
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    return expiry.difference(DateTime.now()) <= leadTime;
  }
}
