import '../../../services/chat_file_access.dart';
// FILE: lib/src/ui/chats/forward/forward_outbox.dart
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ForwardOutboxData {
  final String? text;
  final List<String> fileUrls;
  final List<String> fileIds;
  ForwardOutboxData({this.text, required this.fileUrls, required this.fileIds});
}

class ForwardOutbox {
  static String _key(String chatId) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) throw StateError('Authentication required');
    return 'forward_outbox_${uid}_$chatId';
  }

  static Future<void> putForChat({
    required String chatId,
    String? text,
    List<String> fileUrls = const [],
    List<String> fileIds = const [],
  }) async {
    final key = _key(chatId);
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{
      'text': text ?? '',
      'files': fileUrls,
      'file_ids': fileIds,
    };
    await prefs.setString(key, jsonEncode(map));
  }

  static Future<ForwardOutboxData?> tryTakeForChat(String chatId) async {
    if (Supabase.instance.client.auth.currentUser == null) return null;
    final uid = ChatFileAccess.userId, epoch = ChatFileAccess.generation;
    final key = _key(chatId);
    final prefs = await SharedPreferences.getInstance();
    if (uid != ChatFileAccess.userId || epoch != ChatFileAccess.generation)
      return null;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    await prefs.remove(key);
    if (uid != ChatFileAccess.userId || epoch != ChatFileAccess.generation)
      return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final text = (map['text'] as String?) ?? '';
      final files = (map['files'] as List?)
              ?.map((e) => (e ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      final ids = (map['file_ids'] as List?)
              ?.map((e) => (e ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      return ForwardOutboxData(text: text, fileUrls: files, fileIds: ids);
    } catch (_) {
      return null;
    }
  }
}
