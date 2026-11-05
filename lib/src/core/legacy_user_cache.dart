import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads the old shared profile key only for the session which owns it.
class LegacyUserCache {
  static Future<Map<String, dynamic>?> read({
    required Session? Function() currentSession,
    Future<SharedPreferences> Function()? preferences,
  }) async {
    final initial = currentSession();
    if (initial == null || initial.user.id.isEmpty) return null;
    final owner = (initial.user.id, initial.accessToken, initial.refreshToken);
    try {
      final prefs = await (preferences ?? SharedPreferences.getInstance)();
      final current = currentSession();
      if (current == null ||
          (current.user.id, current.accessToken, current.refreshToken) != owner) {
        return null;
      }
      final raw = prefs.getString('user');
      if (raw == null) return null;
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value['id'] != owner.$1) return null;
      return value;
    } catch (_) {
      return null;
    }
  }
}
