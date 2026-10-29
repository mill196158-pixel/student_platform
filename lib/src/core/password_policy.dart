import 'package:supabase_flutter/supabase_flutter.dart';

/// Unknown profile state must never be interpreted as permission to enter.
bool requirePasswordChangeFromRow(Map<String, dynamic>? row) {
  final flag = row?['must_change_password'];
  if (flag is! bool) {
    throw StateError(
        'Не удалось проверить безопасность профиля. Повторите вход.');
  }
  return flag;
}

Future<bool> loadPasswordChangeRequired(SupabaseClient client) async {
  final uid = client.auth.currentUser?.id;
  if (uid == null) throw StateError('Сессия отсутствует. Повторите вход.');
  final row = await client
      .from('users')
      .select('must_change_password')
      .eq('id', uid)
      .maybeSingle();
  // Do not apply a response belonging to a previous account.
  if (client.auth.currentUser?.id != uid) {
    throw StateError('Аккаунт изменился. Повторите вход.');
  }
  return requirePasswordChangeFromRow(row);
}

Future<String?> authRouteRedirect({
  required String path,
  required bool hasSession,
  required Future<bool> Function() passwordChangeRequired,
}) async {
  if (path == '/login' || path == '/splash') return null;
  if (!hasSession) return '/login';
  if (path == '/change-password') return null;
  try {
    return await passwordChangeRequired() ? '/change-password' : null;
  } catch (_) {
    return '/login';
  }
}
