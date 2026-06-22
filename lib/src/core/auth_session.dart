import 'package:supabase_flutter/supabase_flutter.dart';

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
    try {
      final session = client.auth.currentSession;
      if (session != null && !session.isExpired) {
        return true;
      }
      final response = await client.auth.refreshSession();
      return response.session != null;
    } catch (_) {
      return false;
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
