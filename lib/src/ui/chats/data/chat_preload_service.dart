import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

class ChatPreloadService {
  ChatPreloadService._();

  static bool _running = false;
  static bool _queued = false;
  static Timer? _scheduledWarmUp;
  static DateTime? _lastServerWarmUpAt;
  static final Map<String, DateTime> _warmedAtByChatId = <String, DateTime>{};
  static const Duration _serverWarmUpThrottle = Duration(seconds: 90);
  static const Duration _chatWarmTtl = Duration(minutes: 2);

  static void scheduleWarmUpFromServer({
    Duration delay = const Duration(milliseconds: 900),
    int limit = 12,
    int parallel = 2,
  }) {
    _scheduledWarmUp?.cancel();
    _scheduledWarmUp = Timer(delay, () {
      unawaited(warmUpFromServer(limit: limit, parallel: parallel));
    });
  }

  static Future<void> warmUpFromServer({
    int limit = 12,
    int parallel = 2,
  }) async {
    final now = DateTime.now();
    final last = _lastServerWarmUpAt;
    if (last != null && now.difference(last) < _serverWarmUpThrottle) {
      return;
    }
    if (_running) {
      _queued = true;
      return;
    }
    _running = true;
    _lastServerWarmUpAt = now;
    try {
      do {
        _queued = false;
        final sb = Supabase.instance.client;
        if (sb.auth.currentUser == null) return;

        final res = await sb.rpc('get_my_chat_summaries');
        final entries = (res as List? ?? const [])
            .map((row) => _PreloadChat.fromRow(Map<String, dynamic>.from(
                  row as Map,
                )))
            .where((chat) => chat.chatId.isNotEmpty)
            .toList()
          ..sort(_comparePreloadChats);

        await warmUpChatIds(
          entries.map((chat) => chat.chatId),
          limit: limit,
          parallel: parallel,
        );
      } while (_queued);
    } catch (e) {
      safeDebugLog('[ChatPreload] warmUpFromServer failed: $e');
    } finally {
      _running = false;
    }
  }

  static Future<void> warmUpChatIds(
    Iterable<String?> chatIds, {
    int limit = 12,
    int parallel = 2,
  }) async {
    final ids = <String>[];
    final now = DateTime.now();
    for (final raw in chatIds) {
      final id = (raw ?? '').trim();
      final warmedAt = _warmedAtByChatId[id];
      final stillWarm =
          warmedAt != null && now.difference(warmedAt) < _chatWarmTtl;
      if (id.isEmpty || stillWarm || ids.contains(id)) {
        continue;
      }
      ids.add(id);
      if (ids.length >= limit) break;
    }
    if (ids.isEmpty) return;

    safeDebugLog('[ChatPreload] warming ${ids.length} chats');

    final chunkSize = parallel.clamp(1, 4);
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.skip(i).take(chunkSize).toList();
      await Future.wait(chunk.map((chatId) async {
        try {
          final messages = await DmApi.refreshStream(chatId: chatId);
          _warmedAtByChatId[chatId] = DateTime.now();
          safeDebugLog(
            '[ChatPreload] warmed chat=${maskDebugId(chatId)} messages=${messages.length}',
          );
        } catch (e) {
          safeDebugLog(
            '[ChatPreload] warm failed chat=${maskDebugId(chatId)}: $e',
          );
        }
      }));
    }
  }

  static int _comparePreloadChats(_PreloadChat a, _PreloadChat b) {
    final byUnread = (a.unread > 0 ? 0 : 1).compareTo(b.unread > 0 ? 0 : 1);
    if (byUnread != 0) return byUnread;
    final byUnreadCount = b.unread.compareTo(a.unread);
    if (byUnreadCount != 0) return byUnreadCount;
    final aa = a.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bb = b.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bb.compareTo(aa);
  }
}

class _PreloadChat {
  const _PreloadChat({
    required this.chatId,
    required this.unread,
    required this.lastTime,
  });

  final String chatId;
  final int unread;
  final DateTime? lastTime;

  factory _PreloadChat.fromRow(Map<String, dynamic> row) {
    return _PreloadChat(
      chatId: (row['chat_id'] ?? '').toString(),
      unread: (row['unread_count'] as num?)?.toInt() ?? 0,
      lastTime: DateTime.tryParse((row['last_message_at'] ?? '').toString()),
    );
  }
}
