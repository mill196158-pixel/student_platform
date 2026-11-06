import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persistent friends-screen snapshot with a synchronous first-paint layer.
class FriendsSnapshotCache {
  FriendsSnapshotCache._();

  static const String _keyPrefix = 'friends_snapshot_cache_v1';
  static final Map<String, String> _memory = <String, String>{};
  static SharedPreferences? _prefs;
  static int _memoryEpoch = 0;

  static String _key(String userId) => '${_keyPrefix}_$userId';

  static Future<void> initializeCurrentUser({
    @visibleForTesting Future<SharedPreferences> Function()? preferences,
    @visibleForTesting String? userIdForTesting,
  }) async {
    final epoch = _memoryEpoch;
    final prefs =
        _prefs ?? await (preferences ?? SharedPreferences.getInstance)();
    if (epoch != _memoryEpoch) return;
    _prefs ??= prefs;
    final userId = (userIdForTesting ??
            Supabase.instance.client.auth.currentUser?.id ??
            '')
        .trim();
    if (userId.isEmpty) return;
    final raw = _prefs!.getString(_key(userId));
    if (raw != null && raw.isNotEmpty) {
      _memory.putIfAbsent(userId, () => raw);
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

  static Future<String?> read(
    String userId, {
    @visibleForTesting Future<SharedPreferences> Function()? preferences,
  }) async {
    if (userId.isEmpty) return null;
    final memory = _memory[userId];
    if (memory != null && memory.isNotEmpty) return memory;
    final epoch = _memoryEpoch;
    final prefs =
        _prefs ?? await (preferences ?? SharedPreferences.getInstance)();
    if (epoch != _memoryEpoch) return null;
    _prefs ??= prefs;
    final current = _memory[userId];
    if (current != null && current.isNotEmpty) return current;
    final raw = _prefs!.getString(_key(userId));
    if (raw != null && raw.isNotEmpty) {
      return _memory.putIfAbsent(userId, () => raw);
    }
    return raw;
  }

  static Future<void> write(String userId, String raw) async {
    if (userId.isEmpty || raw.isEmpty) return;
    _memory[userId] = raw;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key(userId), raw);
  }

  @visibleForTesting
  static void debugResetForTest() {
    clearMemory();
    _prefs = null;
  }

  static void clearMemory() {
    _memoryEpoch++;
    _memory.clear();
  }
}
