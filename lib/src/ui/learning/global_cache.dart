import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import 'models/chat_file.dart';

class GlobalCache {
  static final GlobalCache _instance = GlobalCache._internal();
  factory GlobalCache() => _instance;
  GlobalCache._internal();

  // Ключи для SharedPreferences
  static const String _fileCacheKey = 'global_file_cache';
  static const String _draftTextsKey = 'global_draft_texts';
  static const String _draftFilesKey = 'global_draft_files';

  // Глобальный кэш файлов
  final Map<String, ChatFile> _fileCache = {};

  // Глобальные черновики для каждого чата
  final Map<String, String> _draftTexts = {};
  final Map<String, List<Map<String, dynamic>>> _draftFiles = {};

  // Получаем файл из кэша
  ChatFile? getFile(String fileId) {
    final file = _fileCache[fileId];
    if (file != null) {
      safeDebugLog('[GlobalCache] file cache hit id=${maskDebugId(fileId)}');
    } else {
      safeDebugLog('[GlobalCache] file cache miss id=${maskDebugId(fileId)}');
    }
    return file;
  }

  // Сохраняем файл в кэш
  Future<void> cacheFile(String fileId, ChatFile file) async {
    _fileCache[fileId] = file;
    await _saveFileCache();
    safeDebugLog('[GlobalCache] file cached id=${maskDebugId(fileId)}');
  }

  // Сохраняем черновик для чата
  Future<void> saveDraft(
      String chatId, String text, List<Map<String, dynamic>> files) async {
    _draftTexts[chatId] = text;
    _draftFiles[chatId] = List.from(files);
    await _saveDrafts();
    safeDebugLog(
        '[GlobalCache] draft saved chat=${maskDebugId(chatId)} files=${files.length} hasText=${text.isNotEmpty}');
  }

  // Получаем черновик для чата
  (String, List<Map<String, dynamic>>)? getDraft(String chatId) {
    final text = _draftTexts[chatId] ?? '';
    final files = _draftFiles[chatId] ?? [];

    if (text.isNotEmpty || files.isNotEmpty) {
      safeDebugLog(
          '[GlobalCache] draft restored chat=${maskDebugId(chatId)} files=${files.length} hasText=${text.isNotEmpty}');
      return (text, files);
    }
    return null;
  }

  // Очищаем черновик для чата
  Future<void> clearDraft(String chatId) async {
    _draftTexts.remove(chatId);
    _draftFiles.remove(chatId);
    await _saveDrafts();
    safeDebugLog('[GlobalCache] draft cleared chat=${maskDebugId(chatId)}');
  }

  // Очищаем весь кэш
  Future<void> clearAll() async {
    _fileCache.clear();
    _draftTexts.clear();
    _draftFiles.clear();
    await _saveAll();
    safeDebugLog('[GlobalCache] cache cleared');
  }

  // Инициализация - загружаем данные из SharedPreferences
  Future<void> initialize() async {
    safeDebugLog('[GlobalCache] initialization started');
    await _loadFileCache();
    await _loadDrafts();
    safeDebugLog(
        '[GlobalCache] initialized files=${_fileCache.length} drafts=${_draftTexts.length}');
  }

  // Сохраняем кэш файлов
  Future<void> _saveFileCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fileCacheData = <String, String>{};

      for (final entry in _fileCache.entries) {
        fileCacheData[entry.key] = jsonEncode(entry.value.toJson());
      }

      await prefs.setString(_fileCacheKey, jsonEncode(fileCacheData));
    } catch (e) {
      safeDebugLog('[GlobalCache] failed to save file cache: ${e.runtimeType}');
    }
  }

  // Загружаем кэш файлов
  Future<void> _loadFileCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fileCacheJson = prefs.getString(_fileCacheKey);

      if (fileCacheJson != null) {
        final fileCacheData =
            Map<String, dynamic>.from(jsonDecode(fileCacheJson));

        for (final entry in fileCacheData.entries) {
          final fileData = jsonDecode(entry.value);
          _fileCache[entry.key] = ChatFile.fromJson(fileData);
        }

        safeDebugLog(
            '[GlobalCache] file cache loaded count=${_fileCache.length}');
      }
    } catch (e) {
      safeDebugLog('[GlobalCache] failed to load file cache: ${e.runtimeType}');
    }
  }

  // Сохраняем черновики
  Future<void> _saveDrafts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_draftTextsKey, jsonEncode(_draftTexts));
      await prefs.setString(_draftFilesKey, jsonEncode(_draftFiles));
    } catch (e) {
      safeDebugLog('[GlobalCache] failed to save drafts: ${e.runtimeType}');
    }
  }

  // Загружаем черновики
  Future<void> _loadDrafts() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final draftTextsJson = prefs.getString(_draftTextsKey);
      if (draftTextsJson != null) {
        _draftTexts
            .addAll(Map<String, String>.from(jsonDecode(draftTextsJson)));
      }

      final draftFilesJson = prefs.getString(_draftFilesKey);
      if (draftFilesJson != null) {
        final draftFilesData = jsonDecode(draftFilesJson);
        for (final entry in draftFilesData.entries) {
          _draftFiles[entry.key] = List<Map<String, dynamic>>.from(entry.value);
        }
      }

      safeDebugLog('[GlobalCache] drafts loaded count=${_draftTexts.length}');
    } catch (e) {
      safeDebugLog('[GlobalCache] failed to load drafts: ${e.runtimeType}');
    }
  }

  // Сохраняем все данные
  Future<void> _saveAll() async {
    await _saveFileCache();
    await _saveDrafts();
  }

  // Показать статистику кэша
  void showCacheStats() {
    safeDebugLog(
        '[GlobalCache] stats files=${_fileCache.length} drafts=${_draftTexts.length}');
  }
}
