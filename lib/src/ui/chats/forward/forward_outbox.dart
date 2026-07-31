// FILE: lib/src/ui/chats/forward/forward_outbox.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ForwardOutboxData {
  final String? text;
  final List<String> fileUrls;
  final List<String> fileIds;
  ForwardOutboxData({this.text, required this.fileUrls, required this.fileIds});
}

class ForwardOutbox {
  static String _key(String chatId) => 'forward_outbox_' + chatId;

  static Future<void> putForChat({
    required String chatId,
    String? text,
    List<String> fileUrls = const [],
    List<String> fileIds = const [],
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{
      'text': text ?? '',
      'files': fileUrls,
      'file_ids': fileIds,
    };
    await prefs.setString(_key(chatId), jsonEncode(map));
  }

  static Future<ForwardOutboxData?> tryTakeForChat(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(chatId));
    if (raw == null || raw.isEmpty) return null;
    await prefs.remove(_key(chatId));
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final text = (map['text'] as String?) ?? '';
      final files = (map['files'] as List?)?.map((e) => (e ?? '').toString()).where((s) => s.isNotEmpty).toList() ?? const <String>[];
      final ids = (map['file_ids'] as List?)?.map((e) => (e ?? '').toString()).where((s) => s.isNotEmpty).toList() ?? const <String>[];
      return ForwardOutboxData(text: text, fileUrls: files, fileIds: ids);
    } catch (_) {
      return null;
    }
  }
}
