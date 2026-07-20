import 'dart:async';

import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

/// Quietly warms recent message pages into [ChatMessageCacheStore].
///
/// Does not open Realtime subscriptions — only `syncLatest` pages so opening
/// a chat paints from cache immediately.
class ChatPreloadService {
  ChatPreloadService._();

  static const Duration freshTtl = Duration(minutes: 3);
  static const int defaultMessageLimit = 40;
  static const int defaultParallel = 2;

  static Future<void>? _inFlight;
  static int _generation = 0;

  /// Schedule a delayed warm of [chatIds] (fire-and-forget).
  static void scheduleWarmUpChatIds(
    Iterable<String?> chatIds, {
    Duration delay = const Duration(milliseconds: 400),
    int limit = defaultMessageLimit,
    int parallel = defaultParallel,
    Map<String, String>? lastMessageIdByChat,
  }) {
    final gen = ++_generation;
    final snapshot = chatIds.toList(growable: false);
    final lastIds = Map<String, String>.from(lastMessageIdByChat ?? const {});
    unawaited(() async {
      await Future<void>.delayed(delay);
      if (gen != _generation) return;
      await warmUpChatIds(
        snapshot,
        limit: limit,
        parallel: parallel,
        lastMessageIdByChat: lastIds,
      );
    }());
  }

  /// Warm message history for the given chat ids (top of list / priority).
  static Future<void> warmUpChatIds(
    Iterable<String?> chatIds, {
    int limit = defaultMessageLimit,
    int parallel = defaultParallel,
    Map<String, String>? lastMessageIdByChat,
  }) async {
    final gen = ++_generation;
    final prev = _inFlight;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    if (gen != _generation) return;

    final future = _warmUpChatIdsImpl(
      chatIds,
      limit: limit,
      parallel: parallel.clamp(1, 4),
      lastMessageIdByChat: lastMessageIdByChat ?? const {},
    );
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  /// Prefer warming a single chat first (e.g. after a push).
  static Future<void> warmUpPriorityChat(
    String? chatId, {
    int limit = defaultMessageLimit,
  }) async {
    final id = (chatId ?? '').trim();
    if (id.isEmpty) return;
    await warmUpChatIds([id], limit: limit, parallel: 1);
  }

  static Future<void> _warmUpChatIdsImpl(
    Iterable<String?> chatIds, {
    required int limit,
    required int parallel,
    required Map<String, String> lastMessageIdByChat,
  }) async {
    final ids = <String>[];
    final seen = <String>{};
    for (final raw in chatIds) {
      final id = (raw ?? '').trim();
      if (id.isEmpty || !seen.add(id)) continue;
      ids.add(id);
    }
    if (ids.isEmpty) return;

    safeDebugLog(
      '[ChatPreload] warm start count=${ids.length} parallel=$parallel',
    );

    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (index >= ids.length) return;
        final i = index++;
        final chatId = ids[i];
        try {
          await _warmOne(
            chatId,
            limit: limit,
            expectedLastMessageId: lastMessageIdByChat[chatId],
          );
        } catch (e) {
          safeDebugLog(
            '[ChatPreload] warm failed chat=$chatId: ${e.runtimeType}',
          );
        }
      }
    }

    await Future.wait(
      List.generate(parallel, (_) => worker()),
    );

    safeDebugLog('[ChatPreload] warm done count=${ids.length}');
  }

  static Future<void> _warmOne(
    String chatId, {
    required int limit,
    String? expectedLastMessageId,
  }) async {
    if (ActiveChatTracker.instance.isActive(chatId)) {
      return;
    }

    final needs = await _needsWarm(
      chatId,
      expectedLastMessageId: expectedLastMessageId,
    );
    if (!needs) return;

    await DmApi.syncLatest(
      chatId: chatId,
      limit: limit,
      invalidateClearBoundary: false,
    );
  }

  static Future<bool> _needsWarm(
    String chatId, {
    String? expectedLastMessageId,
  }) async {
    final snap = await ChatMessageCacheStore.read(chatId);
    if (!snap.found) return true;

    final expected = (expectedLastMessageId ?? '').trim();
    if (expected.isNotEmpty) {
      final newestId =
          snap.messages.isEmpty ? '' : snap.messages.last.id.trim();
      if (newestId != expected) return true;
    }

    final synced = snap.lastSyncedAt;
    if (synced == null) return true;
    final age = DateTime.now().toUtc().difference(synced.toUtc());
    return age > freshTtl;
  }
}
