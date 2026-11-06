import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

/// Conservative accounting for temporary files and persisted chat history.
/// A failed or incomplete measurement never authorizes eviction.
class TemporaryCacheBudget {
  static const int limitBytes = 500000000;

  static Future<int?> measure({Directory? root, SharedPreferences? prefs,
      File? historyDatabase}) async {
    if (kIsWeb) return null;
    try {
      final directory = root ?? await getTemporaryDirectory();
      if (!await directory.exists()) return null;
      var bytes = 0;
      await for (final item in directory.list(recursive: true, followLinks: false)) {
        if (item is File) bytes += (await item.stat()).size;
      }
      final store = prefs ?? await SharedPreferences.getInstance();
      for (final key in store.getKeys()) {
        if (!key.startsWith('chat_msg_cache_v1_')) continue;
        final value = store.getString(key);
        if (value != null) bytes += utf8.encode(value).length;
      }
      // The server-only SQLite snapshot has its own physical files outside
      // the temp directory. Count actual DB, WAL and shared-memory bytes.
      final database = historyDatabase ?? (root == null
          ? File('${await sqlite.getDatabasesPath()}/offline_chat_ordinary_v1.db')
          : null);
      if (database != null) {
        final rootPrefix = '${directory.absolute.path}${Platform.pathSeparator}';
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('${database.path}$suffix');
          if (file.absolute.path.startsWith(rootPrefix)) continue;
          if (await file.exists()) bytes += (await file.stat()).size;
        }
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// A lower bound suitable for conservative cleanup decisions. Unclassified
  /// files, mixed envelopes and local messages contribute zero, never making
  /// protected material a reason to discard other cached data.
  static Future<int?> measureProvenTemporary(sqlite.Database history,
      {Directory? root, SharedPreferences? prefs}) async {
    if (kIsWeb) return null;
    try {
      final directory = root ?? await getTemporaryDirectory();
      if (!await directory.exists()) return null;
      var total = 0;
      for (final name in ['news_images_v1', 'guest_news_images_v1', 'content_media_images_v1']) {
        final folder = Directory('${directory.path}/$name');
        final type = await FileSystemEntity.type(folder.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.directory) return null;
        await for (final item in folder.list(recursive: true, followLinks: false)) {
          if (item is File) total += (await item.stat()).size;
        }
      }
      final store = prefs ?? await SharedPreferences.getInstance();
      for (final key in store.getKeys()) {
        if (!key.startsWith('chat_msg_cache_v1_')) continue;
        final raw = store.getString(key);
        if (raw == null) continue;
        try {
          final envelope = jsonDecode(raw);
          if (envelope is! Map || envelope['messages'] is! List) continue;
          for (final message in envelope['messages'] as List) {
            if (_confirmedMessage(message)) total += utf8.encode(jsonEncode(message)).length;
          }
        } catch (_) {
          // Unknown envelopes are protected and excluded.
        }
      }
      final rows = await history.query('chat_server_snapshot',
          columns: ['chat', 'payload'], where: 'chat<>?', whereArgs: ['__chat_summaries__']);
      for (final row in rows) {
        final payload = row['payload'];
        if (payload is! String) continue;
        try {
          final messages = jsonDecode(payload);
          if (messages is List && messages.every(_confirmedMessage)) {
            total += utf8.encode(payload).length;
          }
        } catch (_) {
          // Unknown server snapshots are not counted as reclaimable.
        }
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  static bool _confirmedMessage(Object? value) {
    if (value is! Map) return false;
    final id = value['id'];
    final status = value['delivery_status'];
    final client = value['client_id'] ?? value['clientId'];
    if (id is! String || id.isEmpty || id.startsWith('local_') ||
        status != 'sent' || client != null) return false;
    final localPath = value['imagePath'];
    if (localPath != null && (localPath is! String || localPath.isNotEmpty)) return false;
    final outgoing = value['outboundFileIds'] ?? value['outbound_file_ids'];
    if (outgoing != null && (outgoing is! List || outgoing.isNotEmpty)) return false;
    return true;
  }
}
