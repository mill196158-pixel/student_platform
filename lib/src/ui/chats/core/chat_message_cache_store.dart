import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

/// Single persistent + memory message cache for DM and team chats.
///
/// Presence is [ChatCacheSnapshot.found], never `messages.isNotEmpty`.
/// UI/services must not read SharedPreferences chat keys directly.
class ChatMessageCacheStore {
  ChatMessageCacheStore._();

  static const int envelopeVersion = 1;
  static const int maxCachedMessages = 120;
  static const String _prefsPrefix = 'chat_msg_cache_v1_';

  static final Map<String, ChatCacheSnapshot> _memory = {};
  static SharedPreferences? _prefsOverride;
  static SharedPreferences? _prefs;

  /// Test hook: inject prefs (or clear with null).
  static void debugSetPrefs(SharedPreferences? prefs) {
    _prefsOverride = prefs;
  }

  /// Test hook: pretend this auth user owns cache keys.
  static String? debugUserIdOverride;

  static String _memKey(String userId, String chatId) => '$userId::$chatId';

  static String _prefsKey(String userId, String chatId) =>
      '$_prefsPrefix${userId}_$chatId';

  static String? _resolveUserId(String? userId) {
    final explicit = (userId ?? debugUserIdOverride ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    try {
      final id = (Supabase.instance.client.auth.currentUser?.id ?? '').trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  /// Decode this user's persistent message envelopes before the first frame.
  ///
  /// This lets a service created with an initial chat id synchronously seed its
  /// first view state instead of briefly rendering an empty/loading chat.
  static Future<void> initializeCurrentUser() async {
    try {
      final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
      _prefs = prefs;
      final uid = _resolveUserId(null);
      if (uid == null) return;
      final keyPrefix = '$_prefsPrefix${uid}_';
      for (final prefsKey in prefs.getKeys()) {
        if (!prefsKey.startsWith(keyPrefix)) continue;
        final raw = prefs.getString(prefsKey);
        if (raw == null || raw.isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final envelope = Map<String, dynamic>.from(decoded);
        final chatId = (envelope['chatId'] ?? '').toString();
        if (chatId.isEmpty) continue;
        final snap = _fromEnvelope(envelope, uid);
        if (snap.found) {
          _memory[_memKey(uid, chatId)] = snap;
        }
      }
    } catch (_) {}
  }

  /// Sync memory lookup. Empty list with [ChatCacheSnapshot.found] is a hit.
  static bool hasSnapshot(String chatId, {String? userId}) {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return false;
    return _memory[_memKey(uid, chatId)]?.found == true;
  }

  static ChatCacheSnapshot peek(String chatId, {String? userId}) {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;
    final key = _memKey(uid, chatId);
    final memory = _memory[key];
    if (memory != null) return memory;

    // SharedPreferences is fully memory-backed after initialization, so this
    // remains synchronous even for a user who signed in after app startup.
    final prefs = _prefsOverride ?? _prefs;
    final raw = prefs?.getString(_prefsKey(uid, chatId));
    if (raw == null || raw.isEmpty) return ChatCacheSnapshot.notFound;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return ChatCacheSnapshot.notFound;
      final snap = _fromEnvelope(Map<String, dynamic>.from(decoded), uid);
      if (snap.found) _memory[key] = snap;
      return snap;
    } catch (_) {
      return ChatCacheSnapshot.notFound;
    }
  }

  static List<Message> messagesSync(String chatId, {String? userId}) {
    return List<Message>.unmodifiable(peek(chatId, userId: userId).messages);
  }

  /// Memory first, then persistent store. Empty + found is valid.
  static Future<ChatCacheSnapshot> read(String chatId, {String? userId}) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;

    final key = _memKey(uid, chatId);
    final cached = peek(chatId, userId: uid);
    if (cached.found) return cached;

    try {
      final prefs =
          _prefsOverride ?? _prefs ?? await SharedPreferences.getInstance();
      _prefs ??= prefs;
      final raw = prefs.getString(_prefsKey(uid, chatId));
      if (raw == null || raw.isEmpty) return ChatCacheSnapshot.notFound;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return ChatCacheSnapshot.notFound;
      final snap = _fromEnvelope(Map<String, dynamic>.from(decoded), uid);
      if (!snap.found) return ChatCacheSnapshot.notFound;
      _memory[key] = snap;
      return snap;
    } catch (_) {
      return ChatCacheSnapshot.notFound;
    }
  }

  /// Authoritative replace of the cached message list (including empty).
  static Future<ChatCacheSnapshot> replace({
    required String chatId,
    required Iterable<Message> messages,
    String? userId,
    DateTime? lastSyncedAt,
    DateTime? oldestLoadedAt,
    bool? hasMoreBefore,
    DateTime? clearedAt,
    bool markSynced = true,
  }) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;

    final sorted = _dedupeAndSort(messages);
    final tail = _tail(sorted);
    final now = DateTime.now().toUtc();
    final snap = ChatCacheSnapshot(
      found: true,
      messages: List<Message>.unmodifiable(tail),
      savedAt: now,
      lastSyncedAt: markSynced ? (lastSyncedAt ?? now) : lastSyncedAt,
      oldestLoadedAt: oldestLoadedAt ?? (tail.isEmpty ? null : tail.first.at),
      hasMoreBefore: hasMoreBefore ?? false,
      clearedAt: clearedAt,
    );
    _memory[_memKey(uid, chatId)] = snap;
    await _persist(uid, chatId, snap);
    return snap;
  }

  /// Merge messages into an existing snapshot (or create found snapshot).
  static Future<ChatCacheSnapshot> merge({
    required String chatId,
    required Iterable<Message> messages,
    String? userId,
    DateTime? clearedAt,
    bool? hasMoreBefore,
    bool markSynced = false,
  }) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;
    final prev = peek(chatId, userId: uid);
    final sorted = _dedupeAndSort([...prev.messages, ...messages]);
    return replace(
      chatId: chatId,
      userId: uid,
      messages: sorted,
      lastSyncedAt: markSynced ? DateTime.now().toUtc() : prev.lastSyncedAt,
      oldestLoadedAt: sorted.isEmpty ? null : sorted.first.at,
      hasMoreBefore: hasMoreBefore ?? prev.hasMoreBefore,
      clearedAt: clearedAt ?? prev.clearedAt,
      markSynced: markSynced,
    );
  }

  static Future<ChatCacheSnapshot> upsert(
    String chatId,
    Message message, {
    String? userId,
  }) {
    return merge(chatId: chatId, messages: [message], userId: userId);
  }

  static Future<ChatCacheSnapshot> reconcileUpsert(
    String chatId,
    Message serverMessage, {
    String? clientId,
    String? userId,
  }) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;
    final current = List<Message>.from(peek(chatId, userId: uid).messages);
    current.removeWhere((message) {
      if (!message.isLocal) return false;
      if (clientId != null && clientId.isNotEmpty) {
        return message.clientId == clientId || message.id == clientId;
      }
      return _isLikelySameLocalMessage(message, serverMessage);
    });
    current.add(
        serverMessage.copyWith(deliveryStatus: MessageDeliveryStatus.sent));
    return replace(
      chatId: chatId,
      userId: uid,
      messages: current,
      markSynced: false,
      hasMoreBefore: peek(chatId, userId: uid).hasMoreBefore,
      clearedAt: peek(chatId, userId: uid).clearedAt,
    );
  }

  static Future<ChatCacheSnapshot> remove(
    String chatId,
    String messageId, {
    String? userId,
  }) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;
    final prev = peek(chatId, userId: uid);
    if (!prev.found) return ChatCacheSnapshot.notFound;
    final next = prev.messages.where((m) => m.id != messageId).toList();
    return replace(
      chatId: chatId,
      userId: uid,
      messages: next,
      markSynced: false,
      hasMoreBefore: prev.hasMoreBefore,
      clearedAt: prev.clearedAt,
      lastSyncedAt: prev.lastSyncedAt,
    );
  }

  /// Drop messages at/before personal clear boundary.
  static Future<ChatCacheSnapshot> pruneAtOrBefore(
    String chatId,
    DateTime? clearedAt, {
    String? userId,
  }) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;
    final prev = peek(chatId, userId: uid);
    // Never invent a found snapshot from prune alone.
    if (!prev.found) return ChatCacheSnapshot.notFound;
    if (clearedAt == null) return prev;
    final next = prev.messages.where((m) => m.at.isAfter(clearedAt)).toList();
    return replace(
      chatId: chatId,
      userId: uid,
      messages: next,
      clearedAt: clearedAt,
      markSynced: false,
      hasMoreBefore: prev.hasMoreBefore,
      lastSyncedAt: prev.lastSyncedAt,
    );
  }

  /// Reconcile the latest server page into cache without resurrecting deletes
  /// inside the synced window, while keeping separately loaded older history.
  static List<Message> reconcileLatestPage({
    required List<Message> existing,
    required List<Message> serverPage,
    required int pageLimit,
  }) {
    final locals = existing.where((m) => m.isLocal).toList();
    if (serverPage.isEmpty) {
      return _dedupeAndSort(locals);
    }

    final sortedServer = _dedupeAndSort(serverPage);
    final oldest = sortedServer.first;
    final older = existing.where((m) {
      if (m.isLocal) return false;
      final byTime = m.at.compareTo(oldest.at);
      if (byTime < 0) return true;
      if (byTime > 0) return false;
      return m.id.compareTo(oldest.id) < 0;
    }).toList();

    return _dedupeAndSort([...older, ...sortedServer, ...locals]);
  }

  /// Apply latest page and persist as a found snapshot (empty allowed).
  static Future<ChatCacheSnapshot> applyLatestServerPage({
    required String chatId,
    required List<Message> serverPage,
    required int pageLimit,
    String? userId,
    DateTime? clearedAt,
    bool? hasMoreBefore,
  }) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return ChatCacheSnapshot.notFound;
    final prev = peek(chatId, userId: uid);
    final reconciled = reconcileLatestPage(
      existing: prev.found ? prev.messages : const <Message>[],
      serverPage: serverPage,
      pageLimit: pageLimit,
    );
    final sorted = _dedupeAndSort(reconciled);
    return replace(
      chatId: chatId,
      userId: uid,
      messages: sorted,
      clearedAt: clearedAt ?? prev.clearedAt,
      hasMoreBefore: hasMoreBefore ??
          (serverPage.length >= pageLimit || prev.hasMoreBefore),
      markSynced: true,
      oldestLoadedAt: sorted.isEmpty ? null : sorted.first.at,
    );
  }

  static Future<void> clearChat(String chatId, {String? userId}) async {
    final uid = _resolveUserId(userId);
    if (uid == null || chatId.isEmpty) return;
    _memory.remove(_memKey(uid, chatId));
    try {
      final prefs =
          _prefsOverride ?? _prefs ?? await SharedPreferences.getInstance();
      _prefs ??= prefs;
      await prefs.remove(_prefsKey(uid, chatId));
    } catch (_) {}
  }

  /// Clear in-memory maps for the current (or given) user. Persistent keys for
  /// other users are left alone; call [clearAllMemory] on logout.
  static Future<void> clearUser(String? userId) async {
    final uid = _resolveUserId(userId);
    if (uid == null) {
      await clearAllMemory();
      return;
    }
    final prefix = '$uid::';
    _memory.removeWhere((key, _) => key.startsWith(prefix));
  }

  static Future<void> clearAllMemory() async {
    _memory.clear();
  }

  /// Remove all versioned prefs envelopes (all users on this device).
  static Future<void> clearAllPersistent() async {
    try {
      final prefs =
          _prefsOverride ?? _prefs ?? await SharedPreferences.getInstance();
      _prefs ??= prefs;
      final keys =
          prefs.getKeys().where((k) => k.startsWith(_prefsPrefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  static Future<void> clearOnLogout() async {
    await clearAllMemory();
    await clearAllPersistent();
    debugUserIdOverride = null;
  }

  static Future<void> _persist(
    String userId,
    String chatId,
    ChatCacheSnapshot snap,
  ) async {
    try {
      final prefs =
          _prefsOverride ?? _prefs ?? await SharedPreferences.getInstance();
      _prefs ??= prefs;
      await prefs.setString(
        _prefsKey(userId, chatId),
        jsonEncode(_toEnvelope(userId, chatId, snap)),
      );
    } catch (_) {}
  }

  static Map<String, dynamic> _toEnvelope(
    String userId,
    String chatId,
    ChatCacheSnapshot snap,
  ) {
    return {
      'v': envelopeVersion,
      'userId': userId,
      'chatId': chatId,
      'found': snap.found,
      'savedAt': snap.savedAt?.toIso8601String(),
      'lastSyncedAt': snap.lastSyncedAt?.toIso8601String(),
      'oldestLoadedAt': snap.oldestLoadedAt?.toIso8601String(),
      'hasMoreBefore': snap.hasMoreBefore,
      'clearedAt': snap.clearedAt?.toIso8601String(),
      'messages': snap.messages.map((m) => m.toJson()).toList(),
    };
  }

  static ChatCacheSnapshot _fromEnvelope(
    Map<String, dynamic> map,
    String expectedUserId,
  ) {
    final v = (map['v'] as num?)?.toInt() ?? 0;
    if (v != envelopeVersion) return ChatCacheSnapshot.notFound;
    final userId = (map['userId'] ?? '').toString();
    if (userId.isEmpty || userId != expectedUserId) {
      return ChatCacheSnapshot.notFound;
    }
    final found = map['found'] == true;
    if (!found) return ChatCacheSnapshot.notFound;

    final rawMessages = map['messages'];
    final messages = <Message>[];
    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is! Map) continue;
        final message = Message.fromJson(Map<String, dynamic>.from(item));
        if (message.id.isNotEmpty) messages.add(message);
      }
    }
    final sorted = _dedupeAndSort(messages);
    return ChatCacheSnapshot(
      found: true,
      messages: List<Message>.unmodifiable(sorted),
      savedAt: DateTime.tryParse((map['savedAt'] ?? '').toString()),
      lastSyncedAt: DateTime.tryParse((map['lastSyncedAt'] ?? '').toString()),
      oldestLoadedAt:
          DateTime.tryParse((map['oldestLoadedAt'] ?? '').toString()),
      hasMoreBefore: map['hasMoreBefore'] == true,
      clearedAt: DateTime.tryParse((map['clearedAt'] ?? '').toString()),
    );
  }

  static List<Message> _tail(List<Message> sorted) {
    if (sorted.length <= maxCachedMessages) return sorted;
    return sorted.sublist(sorted.length - maxCachedMessages);
  }

  static List<Message> _dedupeAndSort(Iterable<Message> messages) {
    final byId = <String, Message>{};
    for (final message in messages) {
      if (message.id.isEmpty) continue;
      if (!message.isLocal) {
        String? localDuplicateId;
        for (final entry in byId.entries) {
          if (_isLikelySameLocalMessage(entry.value, message)) {
            localDuplicateId = entry.key;
            break;
          }
        }
        if (localDuplicateId != null) {
          byId.remove(localDuplicateId);
        }
      }
      final previous = byId[message.id];
      byId[message.id] =
          previous == null ? message : _mergeSameMessage(previous, message);
    }

    final list = byId.values.toList()
      ..sort((a, b) {
        final byTime = a.at.compareTo(b.at);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return list;
  }

  static Message _mergeSameMessage(Message previous, Message incoming) {
    final previousName = previous.authorName.trim();
    final incomingName = incoming.authorName.trim();
    final shouldKeepPreviousName = previousName.isNotEmpty &&
        (incomingName.isEmpty ||
            incomingName == 'Студент' ||
            incomingName == 'Вы');
    final shouldKeepPreviousLogin = previous.authorLogin.trim().isNotEmpty &&
        incoming.authorLogin.trim().isEmpty;
    final shouldKeepPreviousAvatar = (incoming.authorAvatarUrl == null ||
            incoming.authorAvatarUrl!.isEmpty) &&
        previous.authorAvatarUrl != null &&
        previous.authorAvatarUrl!.isNotEmpty;

    return incoming.copyWith(
      authorLogin:
          shouldKeepPreviousLogin ? previous.authorLogin : incoming.authorLogin,
      authorName:
          shouldKeepPreviousName ? previous.authorName : incoming.authorName,
      authorAvatarUrl: shouldKeepPreviousAvatar
          ? previous.authorAvatarUrl
          : incoming.authorAvatarUrl,
      userReactions: incoming.userReactions ?? previous.userReactions,
    );
  }

  static bool _isLikelySameLocalMessage(Message local, Message server) {
    if (!local.isLocal || server.isLocal) return false;
    if (local.authorId.isNotEmpty &&
        server.authorId.isNotEmpty &&
        local.authorId != server.authorId) {
      return false;
    }
    if (local.text.trim() != server.text.trim()) return false;
    if ((local.replyToId ?? '') != (server.replyToId ?? '')) return false;
    if (local.type != server.type) return false;
    if (_attachmentsFingerprint(local) != _attachmentsFingerprint(server)) {
      return false;
    }

    final diff = local.at.difference(server.at).abs();
    return diff <= const Duration(seconds: 30);
  }

  static String _attachmentsFingerprint(Message message) {
    final attachments = message.attachments ?? const [];
    final ids = attachments
        .map((file) => file.id)
        .where((id) => id.isNotEmpty)
        .toList()
      ..sort();
    if (ids.isNotEmpty) return ids.join(',');
    return message.fileId ?? '';
  }
}
