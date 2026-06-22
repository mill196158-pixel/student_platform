import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatCopiedFileEntry {
  final String path;
  final String name;
  final String mimeType;
  final bool isImage;
  final DateTime copiedAt;

  const ChatCopiedFileEntry({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.isImage,
    required this.copiedAt,
  });

  Future<bool> get isAvailable async {
    if (DateTime.now().difference(copiedAt) > const Duration(minutes: 30)) {
      return false;
    }
    final file = File(path);
    return await file.exists() && await file.length() > 0;
  }
}

class ChatCopiedFileCache {
  ChatCopiedFileCache._();

  static const _keyPath = 'chat_copied_file_path';
  static const _keyName = 'chat_copied_file_name';
  static const _keyMime = 'chat_copied_file_mime';
  static const _keyIsImage = 'chat_copied_file_is_image';
  static const _keyCopiedAt = 'chat_copied_file_copied_at';

  static ChatCopiedFileEntry? _last;

  static void remember({
    required String path,
    required String name,
    required String mimeType,
    required bool isImage,
  }) {
    final entry = ChatCopiedFileEntry(
      path: path,
      name: name,
      mimeType: mimeType,
      isImage: isImage,
      copiedAt: DateTime.now(),
    );
    _last = entry;
    debugPrint('[ChatCopiedFileCache] remembered name=$name mime=$mimeType');
    unawaited(_persist(entry));
  }

  static Future<ChatCopiedFileEntry?> peek() async {
    final entry = _last ?? await _load();
    if (entry == null) {
      debugPrint('[ChatCopiedFileCache] empty');
      return null;
    }
    if (!await entry.isAvailable) {
      debugPrint('[ChatCopiedFileCache] unavailable path=${entry.path}');
      _last = null;
      unawaited(_clear());
      return null;
    }
    _last = entry;
    debugPrint('[ChatCopiedFileCache] hit name=${entry.name}');
    return entry;
  }

  static Future<void> _persist(ChatCopiedFileEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyPath, entry.path);
      await prefs.setString(_keyName, entry.name);
      await prefs.setString(_keyMime, entry.mimeType);
      await prefs.setBool(_keyIsImage, entry.isImage);
      await prefs.setString(_keyCopiedAt, entry.copiedAt.toIso8601String());
    } catch (_) {}
  }

  static Future<ChatCopiedFileEntry?> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(_keyPath);
      final name = prefs.getString(_keyName);
      final mime = prefs.getString(_keyMime);
      final copiedAt = DateTime.tryParse(prefs.getString(_keyCopiedAt) ?? '');
      if (path == null ||
          path.isEmpty ||
          name == null ||
          name.isEmpty ||
          mime == null ||
          mime.isEmpty ||
          copiedAt == null) {
        return null;
      }
      return ChatCopiedFileEntry(
        path: path,
        name: name,
        mimeType: mime,
        isImage: prefs.getBool(_keyIsImage) ?? mime.startsWith('image/'),
        copiedAt: copiedAt,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyPath);
      await prefs.remove(_keyName);
      await prefs.remove(_keyMime);
      await prefs.remove(_keyIsImage);
      await prefs.remove(_keyCopiedAt);
    } catch (_) {}
  }
}
