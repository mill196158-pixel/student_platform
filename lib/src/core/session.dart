import 'package:supabase_flutter/supabase_flutter.dart';

class AppSession {
  static String _login = '';
  static String _groupName = '';

  static String get login => _login;
  static String get groupName => _groupName;
  static bool get isReady => _login.isNotEmpty || _groupName.isNotEmpty;

  static void setUser(String login, String groupName) {
    _login = login.trim();
    _groupName = groupName.trim();
  }

  static void clear() {
    _login = '';
    _groupName = '';
  }

  /// Грузит профиль через SECURITY DEFINER RPC (без RLS-головной боли).
  static Future<void> loadFromServer() async {
    final sb = Supabase.instance.client;
    final sess = sb.auth.currentSession;
    if (sess == null) return;

    try {
      final res = await sb.rpc('get_my_profile');
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        setUser((m['login'] ?? '').toString(), (m['group_name'] ?? '').toString());
      } else if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        setUser((m['login'] ?? '').toString(), (m['group_name'] ?? '').toString());
      }
    } catch (_) {
      // молча: сессия есть, но профиля нет или права — не считаем это фаталом.
    }
  }
}
