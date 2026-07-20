import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/image_cache_service.dart';
import 'package:student_platform/src/ui/chats/data/chat_preload_service.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';

/// App-level quiet warm-up while the user is in the app (not necessarily in chats).
///
/// 1) Refreshes `get_my_chat_summaries` into the same prefs cache as [MyChatsScreen]
/// 2) Prefetches recent message pages for the top N chats into [ChatMessageCacheStore]
/// 3) Prefetches a few avatar URLs
class ChatWarmCoordinator with WidgetsBindingObserver {
  ChatWarmCoordinator._();
  static final ChatWarmCoordinator instance = ChatWarmCoordinator._();

  static const String _cacheKeyPrefix = 'my_chats_cache_v2';
  static const int topChatsToWarm = 8;
  static const int messagePageLimit = 40;
  static const Duration _initialDelay = Duration(milliseconds: 900);
  static const Duration _resumeDelay = Duration(milliseconds: 500);
  static const Duration _minRefreshGap = Duration(seconds: 45);

  bool _started = false;
  bool _observerAttached = false;
  Future<void>? _refreshInFlight;
  DateTime? _lastRefreshAt;
  Timer? _pendingTimer;

  String _cacheKeyFor(String userId) => '${_cacheKeyPrefix}_$userId';

  /// Call once after the main shell is up (authenticated home/nav).
  void start() {
    if (_started) {
      scheduleRefresh(delay: _initialDelay);
      return;
    }
    _started = true;
    if (!_observerAttached) {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    }
    scheduleRefresh(delay: _initialDelay);
  }

  void stop() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      scheduleRefresh(delay: _resumeDelay);
    }
  }

  /// Debounced fire-and-forget refresh + warm.
  void scheduleRefresh({Duration delay = Duration.zero}) {
    _pendingTimer?.cancel();
    _pendingTimer = Timer(delay, () {
      unawaited(refreshNow());
    });
  }

  /// Warm one chat ASAP (foreground push / open intent).
  void prioritizeChat(String? chatId) {
    final id = (chatId ?? '').trim();
    if (id.isEmpty) return;
    unawaited(ChatPreloadService.warmUpPriorityChat(id));
  }

  Future<void> refreshNow({bool force = false}) async {
    final existing = _refreshInFlight;
    if (existing != null) return existing;

    if (!force &&
        _lastRefreshAt != null &&
        DateTime.now().difference(_lastRefreshAt!) < _minRefreshGap) {
      return;
    }

    final future = _refreshImpl();
    _refreshInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    }
  }

  Future<void> _refreshImpl() async {
    final sb = Supabase.instance.client;
    final me = sb.auth.currentUser?.id;
    if (me == null || me.isEmpty) return;

    safeDebugLog('[ChatWarm] refresh start');
    try {
      final res = await sb.rpc('get_my_chat_summaries');
      final rows = (res as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final summaries = <Map<String, dynamic>>[];
      for (final row in rows) {
        final mapped = _summaryMapFromRpcRow(row);
        if (mapped == null) continue;
        summaries.add(mapped);
      }

      summaries.sort(_compareSummaryMaps);

      await _saveSummariesCache(me, summaries);

      final avatarUrls = <String>[];
      final lastMessageIdByChat = <String, String>{};
      final chatIds = <String>[];

      for (final m in summaries) {
        if (chatIds.length >= topChatsToWarm) break;
        final chatId = (m['chatId'] ?? '').toString().trim();
        if (chatId.isEmpty) continue;
        chatIds.add(chatId);
        final lastId = (m['lastMessageId'] ?? '').toString().trim();
        if (lastId.isNotEmpty) lastMessageIdByChat[chatId] = lastId;
        final avatar = (m['avatarUrl'] ?? '').toString().trim();
        if (avatar.isNotEmpty) avatarUrls.add(avatar);
      }

      if (avatarUrls.isNotEmpty) {
        unawaited(AppImageCache().prefetchUrls(avatarUrls.take(12)));
      }

      if (chatIds.isNotEmpty) {
        await ChatPreloadService.warmUpChatIds(
          chatIds,
          limit: messagePageLimit,
          parallel: ChatPreloadService.defaultParallel,
          lastMessageIdByChat: lastMessageIdByChat,
        );
      }

      _lastRefreshAt = DateTime.now();
      safeDebugLog(
        '[ChatWarm] refresh done summaries=${summaries.length} warmed=${chatIds.length}',
      );
    } catch (e) {
      safeDebugLog('[ChatWarm] refresh failed: ${e.runtimeType}');
    }
  }

  Future<void> _saveSummariesCache(
    String userId,
    List<Map<String, dynamic>> summaries,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKeyFor(userId), jsonEncode(summaries));
    } catch (_) {}
  }

  static int _compareSummaryMaps(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final ap = a['pinned'] == true;
    final bp = b['pinned'] == true;
    if (ap != bp) return ap ? -1 : 1;
    final aa = DateTime.tryParse((a['lastTime'] ?? '').toString()) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final bb = DateTime.tryParse((b['lastTime'] ?? '').toString()) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return bb.compareTo(aa);
  }

  /// Same shape as [MyChatsScreen] prefs cache so hydrate picks it up.
  static Map<String, dynamic>? _summaryMapFromRpcRow(Map<String, dynamic> row) {
    final chatType = (row['chat_type'] ?? '').toString();
    final isDm = chatType == 'dm';
    final peerId = (row['peer_id'] ?? '').toString();
    if (isDm && peerId.isEmpty) return null;

    final teamId = (row['team_id'] ?? '').toString();
    final teamName = (row['team_name'] ?? '').toString();
    final teamIcon = (row['team_icon'] ?? '').toString();
    final teamTeacher = (row['team_teacher'] ?? '').toString();
    final teamGroupName = (row['team_group_name'] ?? '').toString();
    final titleRaw = (row['title'] ?? '').toString().trim();
    final avatarRaw = (row['avatar_url'] ?? '').toString().trim();
    final chatId = (row['chat_id'] ?? '').toString();
    final lastMessageId = (row['last_message_id'] ?? '').toString();
    final lastAt = DateTime.tryParse((row['last_message_at'] ?? '').toString());
    final lastAuthorName = (row['last_author_name'] ?? '').toString().trim();
    final unread = (row['unread_count'] as num?)?.toInt() ?? 0;
    final pinned = row['is_pinned'] == true;
    final muted = row['is_muted'] == true;

    final hasLastMessage = lastMessageId.isNotEmpty;
    final preview = hasLastMessage
        ? _buildPreviewFromRow(row)
        : 'Сообщений пока нет';

    final title = isDm
        ? normalizeDmTitle(titleRaw)
        : (titleRaw.isNotEmpty
            ? titleRaw
            : (teamName.isNotEmpty ? teamName : 'Чат'));

    return {
      'team': {
        'id': isDm ? '' : teamId,
        'name': isDm ? title : (teamName.isNotEmpty ? teamName : title),
        'teacher': teamTeacher,
        'groupCode': teamGroupName,
        'icon': teamIcon,
      },
      'title': title,
      'subtitle': null,
      'lastAuthor': lastAuthorName.isEmpty ? null : lastAuthorName,
      'lastMsgPreview': preview,
      'lastTime': lastAt?.toIso8601String(),
      'unread': unread,
      'pinned': pinned,
      'muted': muted,
      'chatId': chatId.isEmpty ? null : chatId,
      'lastMessageId': lastMessageId.isEmpty ? null : lastMessageId,
      'isDm': isDm,
      'peerId': peerId.isEmpty ? null : peerId,
      'avatarUrl': avatarRaw.isEmpty ? null : avatarRaw,
    };
  }

  static String _buildPreviewFromRow(Map<String, dynamic> row) {
    final body = (row['body'] ?? row['content'] ?? '').toString().trim();
    if (body.isNotEmpty) {
      return body.length > 120 ? '${body.substring(0, 120)}…' : body;
    }
    final msgType = (row['msg_type'] ?? '').toString();
    if (msgType == 'file' || msgType == 'image') return '📎 Вложение';
    return 'Сообщение';
  }
}
