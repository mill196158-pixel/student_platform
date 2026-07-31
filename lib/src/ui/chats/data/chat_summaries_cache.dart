import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persistent chat-list cache with a synchronous memory layer for first paint.
class ChatSummariesCache {
  ChatSummariesCache._();

  static const String _keyPrefix = 'my_chats_cache_v2';
  static final Map<String, String> _memory = <String, String>{};
  static SharedPreferences? _prefs;

  static String _key(String userId) => '${_keyPrefix}_$userId';

  /// Prime the current user's chat list before the first Flutter frame.
  static Future<void> initializeCurrentUser() async {
    _prefs ??= await SharedPreferences.getInstance();
    final userId = (Supabase.instance.client.auth.currentUser?.id ?? '').trim();
    if (userId.isEmpty) return;
    final raw = _prefs!.getString(_key(userId));
    if (raw != null && raw.isNotEmpty) {
      _memory[userId] = raw;
    }
  }

  static String? readSync(String userId) {
    if (userId.isEmpty) return null;
    final memory = _memory[userId];
    if (memory != null) return memory;
    final raw = _prefs?.getString(_key(userId));
    if (raw != null && raw.isNotEmpty) {
      _memory[userId] = raw;
    }
    return raw;
  }

  static Future<String?> read(String userId) async {
    if (userId.isEmpty) return null;
    final memory = _memory[userId];
    if (memory != null && memory.isNotEmpty) return memory;
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key(userId));
    if (raw != null && raw.isNotEmpty) {
      _memory[userId] = raw;
    }
    return raw;
  }

  static Future<void> write(String userId, String raw) async {
    if (userId.isEmpty || raw.isEmpty) return;
    _memory[userId] = raw;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key(userId), raw);
  }

  static void clearMemory() => _memory.clear();
}
