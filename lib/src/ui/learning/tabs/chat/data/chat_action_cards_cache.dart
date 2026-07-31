// =============================
// FILE: lib/src/ui/learning/tabs/chat/data/chat_action_cards_cache.dart
// =============================
//
// Stage 13.12 — batch cache for group-action ("card") previews.
//
// Root cause this file fixes: [TopicSelectionCard] / [CollectionCard] each
// independently called a chat-wide "list all selections/collections" RPC
// just to find their own row. With many cards in a chat this means N
// redundant network calls for the same page load. This cache batches all
// visible card lookups (topic_selection + group_collection) into a single
// `get_chat_action_cards_batch` RPC call per chat, keeps an in-memory
// key(kind+entityId) → row map, persists a last-known snapshot per user+chat
// to [SharedPreferences] for offline/cold-start, and falls back to the
// legacy per-kind list RPCs (still batched — never one call per card) when
// the Stage 13.12 batch RPC is unavailable on the connected backend.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../models/message.dart';
import '../models/chat_group_actions.dart';
import 'chat_group_actions_repository.dart';

/// Canonical card kinds used as cache keys. Wire-compatible aliases
/// (`topic` / `collection`) are normalized via [ChatActionCardsCache.canonicalKind].
class ChatActionCardKind {
  static const topicSelection = 'topic_selection';
  static const groupCollection = 'group_collection';
}

/// A single resolved (or tombstoned) card row.
class ChatActionCardEntry {
  const ChatActionCardEntry({
    required this.kind,
    required this.entityId,
    this.cardMessageId,
    this.available = false,
    this.status = 'unavailable',
    this.title = '',
    this.description = '',
    this.purpose = '',
    this.rowVersion,
    this.deadlineAt,
    this.allowChange,
    this.freeSlots = 0,
    this.takenSlots = 0,
    this.totalCapacity = 0,
    this.myPickText,
    this.myStatus,
    this.amountMode,
    this.amountOptional,
    this.amountTotal,
    this.createdBy,
    this.compactCompleted = false,
    this.legacyGroupSpace = false,
    this.organizerStats,
    this.canManage,
    this.canDelete,
    this.options,
    this.tombstoned = false,
  });

  final String kind; // ChatActionCardKind.topicSelection | groupCollection
  final String entityId;
  final String? cardMessageId;
  final bool available;
  final String status;
  final String title;
  final String description;
  final String purpose;
  final int? rowVersion;
  final DateTime? deadlineAt;
  final bool? allowChange;
  final int freeSlots;
  final int takenSlots;
  final int totalCapacity;
  final String? myPickText;
  final String? myStatus;
  final String? amountMode;
  final double? amountOptional;
  final double? amountTotal;
  final String? createdBy;
  final bool compactCompleted;
  final bool legacyGroupSpace;
  final Map<String, dynamic>? organizerStats;
  final bool? canManage;
  /// Server SoT from batch projection (`group_action_can_delete` rules).
  final bool? canDelete;
  final List<Map<String, dynamic>>? options;

  /// True when this row was explicitly marked deleted/unavailable client-side
  /// (e.g. after a 404 from the server) rather than merely "not yet loaded".
  final bool tombstoned;

  bool get isTopic => kind == ChatActionCardKind.topicSelection;
  bool get isCollection => kind == ChatActionCardKind.groupCollection;
  bool get isClosed => compactCompleted || (status != 'open' && available);

  ChatActionCardEntry copyWith({
    bool? available,
    String? status,
    bool? tombstoned,
  }) {
    return ChatActionCardEntry(
      kind: kind,
      entityId: entityId,
      cardMessageId: cardMessageId,
      available: available ?? this.available,
      status: status ?? this.status,
      title: title,
      description: description,
      purpose: purpose,
      rowVersion: rowVersion,
      deadlineAt: deadlineAt,
      allowChange: allowChange,
      freeSlots: freeSlots,
      takenSlots: takenSlots,
      totalCapacity: totalCapacity,
      myPickText: myPickText,
      myStatus: myStatus,
      amountMode: amountMode,
      amountOptional: amountOptional,
      amountTotal: amountTotal,
      createdBy: createdBy,
      compactCompleted: compactCompleted,
      legacyGroupSpace: legacyGroupSpace,
      organizerStats: organizerStats,
      canManage: canManage,
      canDelete: canDelete,
      options: options,
      tombstoned: tombstoned ?? this.tombstoned,
    );
  }

  static ChatActionCardEntry? fromBatchJson(Map<String, dynamic> row) {
    final kind = ChatActionCardsCache.canonicalKind(
      (row['kind'] ?? '').toString(),
    );
    final entityId = (row['entity_id'] ?? '').toString();
    if (kind.isEmpty || entityId.isEmpty) return null;
    final status = (row['status'] ?? 'unavailable').toString();
    final cancelled = status == 'cancelled';
    return ChatActionCardEntry(
      kind: kind,
      entityId: entityId,
      cardMessageId: _nullableId(row['card_message_id']),
      // Cancelled (= deleted) must not appear as a live card anywhere.
      available: row['available'] == true && !cancelled,
      status: status,
      tombstoned: cancelled,
      title: (row['title'] ?? '').toString(),
      description: (row['description'] ?? '').toString(),
      purpose: (row['purpose'] ?? '').toString(),
      rowVersion: _asIntOrNull(row['row_version']),
      deadlineAt: DateTime.tryParse((row['deadline_at'] ?? '').toString()),
      allowChange:
          row['allow_change'] is bool ? row['allow_change'] as bool : null,
      freeSlots: _asInt(row['free_slots']),
      takenSlots: _asInt(row['taken_slots']),
      totalCapacity: _asInt(row['total_capacity']),
      myPickText: _nullableId(row['my_pick_text']),
      myStatus: _nullableId(row['my_status']),
      amountMode: _nullableId(row['amount_mode']),
      amountOptional: _asDoubleOrNull(row['amount_optional']),
      amountTotal: _asDoubleOrNull(row['amount_total']),
      createdBy: _nullableId(row['created_by']),
      compactCompleted: row['compact_completed'] == true,
      legacyGroupSpace: row['legacy_group_space'] == true,
      organizerStats: row['organizer_stats'] is Map
          ? Map<String, dynamic>.from(row['organizer_stats'] as Map)
          : null,
      canManage: row['can_manage'] is bool ? row['can_manage'] as bool : null,
      canDelete: row['can_delete'] is bool ? row['can_delete'] as bool : null,
      options: row['options'] is List
          ? (row['options'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : null,
    );
  }

  static ChatActionCardEntry fromTopicSelection(ChatTopicSelection s) {
    final cancelled = s.status == 'cancelled';
    return ChatActionCardEntry(
      kind: ChatActionCardKind.topicSelection,
      entityId: s.id,
      cardMessageId: s.cardMessageId,
      available: !cancelled,
      status: s.status,
      tombstoned: cancelled,
      title: s.title,
      description: s.description,
      rowVersion: null,
      deadlineAt: s.deadlineAt,
      allowChange: s.allowChange,
      freeSlots: s.freeSlots,
      takenSlots: s.takenSlots,
      totalCapacity: s.totalCapacity,
      compactCompleted: s.status != 'open',
    );
  }

  static ChatActionCardEntry fromLegacyCollectionJson(
    Map<String, dynamic> map,
  ) {
    final entityId = (map['id'] ?? '').toString();
    final status = (map['status'] ?? 'open').toString();
    final cancelled = status == 'cancelled';
    final confirmed = _asInt(map['confirmed_count']);
    final paidLegacy = _asInt(map['paid_count']);
    final total = map['member_count'] != null
        ? _asInt(map['member_count'])
        : _asInt(map['total_members']);
    return ChatActionCardEntry(
      kind: ChatActionCardKind.groupCollection,
      entityId: entityId,
      cardMessageId: _nullableId(map['card_message_id']),
      available: entityId.isNotEmpty && !cancelled,
      status: status,
      tombstoned: cancelled,
      title: (map['title'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      purpose: (map['purpose'] ?? '').toString(),
      deadlineAt: DateTime.tryParse((map['deadline_at'] ?? '').toString()),
      amountMode: _nullableId(map['amount_mode']),
      amountOptional: _asDoubleOrNull(map['amount_optional']),
      amountTotal: _asDoubleOrNull(map['amount_total']),
      myStatus: _nullableId(
        map['my_payment_status'] ?? map['my_organizer_status'],
      ),
      createdBy: _nullableId(map['created_by']),
      compactCompleted: status != 'open',
      organizerStats: (confirmed > 0 || paidLegacy > 0 || total > 0)
          ? {'confirmed': confirmed, 'total': total}
          : null,
    );
  }

  Map<String, dynamic> toCacheJson() => {
        'kind': kind,
        'entity_id': entityId,
        'card_message_id': cardMessageId,
        'available': available,
        'status': status,
        'title': title,
        'description': description,
        'purpose': purpose,
        'row_version': rowVersion,
        'deadline_at': deadlineAt?.toIso8601String(),
        'allow_change': allowChange,
        'free_slots': freeSlots,
        'taken_slots': takenSlots,
        'total_capacity': totalCapacity,
        'my_pick_text': myPickText,
        'my_status': myStatus,
        'amount_mode': amountMode,
        'amount_optional': amountOptional,
        'amount_total': amountTotal,
        'created_by': createdBy,
        'compact_completed': compactCompleted,
        'legacy_group_space': legacyGroupSpace,
        'organizer_stats': organizerStats,
        'can_manage': canManage,
        'can_delete': canDelete,
        'options': options,
        'tombstoned': tombstoned,
      };

  static ChatActionCardEntry? fromCacheJson(Map<String, dynamic> map) {
    final kind = ChatActionCardsCache.canonicalKind(
      (map['kind'] ?? '').toString(),
    );
    final entityId = (map['entity_id'] ?? '').toString();
    if (kind.isEmpty || entityId.isEmpty) return null;
    final status = (map['status'] ?? 'unavailable').toString();
    final cancelled = status == 'cancelled' || map['tombstoned'] == true;
    return ChatActionCardEntry(
      kind: kind,
      entityId: entityId,
      cardMessageId: _nullableId(map['card_message_id']),
      available: map['available'] == true && !cancelled,
      status: status,
      tombstoned: cancelled,
      title: (map['title'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      purpose: (map['purpose'] ?? '').toString(),
      rowVersion: _asIntOrNull(map['row_version']),
      deadlineAt: DateTime.tryParse((map['deadline_at'] ?? '').toString()),
      allowChange:
          map['allow_change'] is bool ? map['allow_change'] as bool : null,
      freeSlots: _asInt(map['free_slots']),
      takenSlots: _asInt(map['taken_slots']),
      totalCapacity: _asInt(map['total_capacity']),
      myPickText: _nullableId(map['my_pick_text']),
      myStatus: _nullableId(map['my_status']),
      amountMode: _nullableId(map['amount_mode']),
      amountOptional: _asDoubleOrNull(map['amount_optional']),
      amountTotal: _asDoubleOrNull(map['amount_total']),
      createdBy: _nullableId(map['created_by']),
      compactCompleted: map['compact_completed'] == true,
      legacyGroupSpace: map['legacy_group_space'] == true,
      organizerStats: map['organizer_stats'] is Map
          ? Map<String, dynamic>.from(map['organizer_stats'] as Map)
          : null,
      canManage: map['can_manage'] is bool ? map['can_manage'] as bool : null,
      canDelete: map['can_delete'] is bool ? map['can_delete'] as bool : null,
      options: map['options'] is List
          ? (map['options'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : null,
    );
  }

  static String? _nullableId(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int? _asIntOrNull(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static double? _asDoubleOrNull(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}

class _PendingItem {
  _PendingItem(
      {required this.kind, required this.entityId, this.cardMessageId});
  final String kind;
  final String entityId;
  final String? cardMessageId;
}

/// Single-flight, chat-scoped batch cache for topic-selection / collection
/// card previews. See file header for the root cause this fixes.
class ChatActionCardsCache {
  ChatActionCardsCache({SupabaseClient? client}) : _clientOverride = client;

  /// Shared app-wide instance so sibling card widgets in the same chat
  /// screen naturally coalesce their lookups into one batch RPC call.
  static ChatActionCardsCache instance = ChatActionCardsCache();

  final SupabaseClient? _clientOverride;

  /// Resolved lazily so tests can construct/seed a cache without ever
  /// touching `Supabase.instance` (which isn't initialized in widget tests).
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  final Map<String, ChatActionCardEntry> _memory = {};
  final Set<String> _loadedSnapshotChats = {};
  final Map<String, Future<void>> _inFlightHydrate = {};
  final Map<String, List<_PendingItem>> _pendingItems = {};
  final Map<String, List<Completer<ChatActionCardEntry?>>> _pendingCompleters =
      {};
  final Map<String, bool> _flushScheduled = {};
  final Map<String, RealtimeChannel> _channels = {};

  static const _cachePrefix = 'chat_action_cards_cache_v1:';

  String? get _userId => _client.auth.currentUser?.id;

  /// Normalizes wire/legacy kind spellings to the canonical cache key kind.
  static String canonicalKind(String kind) {
    final k = kind.trim().toLowerCase();
    if (k == ChatActionCardKind.topicSelection || k == 'topic') {
      return ChatActionCardKind.topicSelection;
    }
    if (k == ChatActionCardKind.groupCollection || k == 'collection') {
      return ChatActionCardKind.groupCollection;
    }
    return k;
  }

  static String cacheKeyFor(String kind, String entityId) =>
      '${canonicalKind(kind)}:$entityId';

  /// Synchronous read from the in-memory cache. Returns null on a cold miss
  /// (caller should trigger [ensureLoaded] or [hydrateForMessages]).
  ChatActionCardEntry? peek(String kind, String entityId) {
    return _memory[cacheKeyFor(kind, entityId)];
  }

  /// Directly inserts a resolved row into the in-memory cache. Used to seed
  /// pre-fetched data (e.g. from a page-level batch response the caller
  /// already parsed itself) and in tests, without a network round trip.
  void seed(ChatActionCardEntry entry) {
    _memory[cacheKeyFor(entry.kind, entry.entityId)] = entry;
  }

  void invalidate(String kind, String entityId) {
    _memory.remove(cacheKeyFor(kind, entityId));
  }

  /// Targeted Realtime / mutation refresh for one entity. Removes the
  /// in-memory row then re-fetches it (and persists) so picks/status edits
  /// cannot remain permanently stale after an event.
  Future<void> refreshEntity(
    String chatId, {
    required String kind,
    required String entityId,
    String? cardMessageId,
  }) async {
    final id = chatId.trim();
    final entity = entityId.trim();
    if (id.isEmpty || entity.isEmpty) return;
    // Preserve last-known card_message_id — batch RPC requires it.
    final preserved = (cardMessageId ?? '').trim().isNotEmpty
        ? cardMessageId!.trim()
        : peek(kind, entity)?.cardMessageId;
    if (preserved == null || preserved.isEmpty) {
      // Cannot safely refresh without binding; leave last-known entry.
      return;
    }
    invalidate(kind, entity);
    await ensureLoaded(
      id,
      kind: kind,
      entityId: entity,
      cardMessageId: preserved,
      forceNetwork: true,
    );
  }

  final Map<String, int> _channelRefCounts = {};
  final Map<String, Set<String>> _trackedEntities = {};

  void trackEntity(String chatId, String kind, String entityId) {
    final id = chatId.trim();
    if (id.isEmpty || entityId.isEmpty) return;
    _trackedEntities.putIfAbsent(id, () => <String>{}).add(
          cacheKeyFor(kind, entityId),
        );
  }

  /// Subscribe to entity mutations for [chatId] so picks / closes / collection
  /// updates invalidate targeted cache rows. Ref-counted; call [unbindRealtime]
  /// when the chat screen disposes.
  Future<void> bindRealtime(String chatId) async {
    final id = chatId.trim();
    if (id.isEmpty) return;
    _channelRefCounts[id] = (_channelRefCounts[id] ?? 0) + 1;
    if (_channels.containsKey(id)) return;
    try {
      final channel = _client.channel('chat_action_cards_$id');
      bool tracks(String kind, String entityId) {
        final set = _trackedEntities[id];
        if (set == null || set.isEmpty) return true; // cold: allow first binds
        return set.contains(cacheKeyFor(kind, entityId));
      }

      void onEntityChange(PostgresChangePayload payload, String kind) {
        final record = payload.newRecord.isNotEmpty
            ? payload.newRecord
            : payload.oldRecord;
        final entityId = (record['id'] ?? '').toString();
        if (entityId.isEmpty || !tracks(kind, entityId)) return;
        final cardMessageId = record['card_message_id']?.toString();
        unawaited(refreshEntity(
          id,
          kind: kind,
          entityId: entityId,
          cardMessageId: cardMessageId,
        ));
      }

      channel
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'group_topic_selections',
            callback: (p) =>
                onEntityChange(p, ChatActionCardKind.topicSelection),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'group_topic_picks',
            callback: (payload) {
              final record = payload.newRecord.isNotEmpty
                  ? payload.newRecord
                  : payload.oldRecord;
              final selectionId = (record['selection_id'] ?? '').toString();
              if (selectionId.isEmpty ||
                  !tracks(ChatActionCardKind.topicSelection, selectionId)) {
                return;
              }
              unawaited(refreshEntity(
                id,
                kind: ChatActionCardKind.topicSelection,
                entityId: selectionId,
              ));
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'group_collections',
            callback: (p) =>
                onEntityChange(p, ChatActionCardKind.groupCollection),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'group_collection_contributions',
            callback: (payload) {
              final record = payload.newRecord.isNotEmpty
                  ? payload.newRecord
                  : payload.oldRecord;
              final collectionId = (record['collection_id'] ?? '').toString();
              if (collectionId.isEmpty ||
                  !tracks(ChatActionCardKind.groupCollection, collectionId)) {
                return;
              }
              unawaited(refreshEntity(
                id,
                kind: ChatActionCardKind.groupCollection,
                entityId: collectionId,
              ));
            },
          )
          .subscribe();
      _channels[id] = channel;
    } catch (_) {
      // Realtime optional — mutation paths still call refreshEntity.
    }
  }

  Future<void> unbindRealtime(String chatId) async {
    final id = chatId.trim();
    if (id.isEmpty) return;
    final next = (_channelRefCounts[id] ?? 1) - 1;
    if (next > 0) {
      _channelRefCounts[id] = next;
      return;
    }
    _channelRefCounts.remove(id);
    final channel = _channels.remove(id);
    _trackedEntities.remove(id);
    if (channel != null) {
      try {
        await _client.removeChannel(channel);
      } catch (_) {}
    }
  }

  void markTombstone(String kind, String entityId) {
    final key = cacheKeyFor(kind, entityId);
    final existing = _memory[key];
    _memory[key] = (existing ??
            ChatActionCardEntry(
              kind: canonicalKind(kind),
              entityId: entityId,
            ))
        .copyWith(available: false, status: 'unavailable', tombstoned: true);
  }

  /// Batch-hydrates the cache for every card-bearing message in [messages].
  /// Safe to call repeatedly (e.g. on every page load) — single-flight per
  /// [chatId]: a second concurrent call awaits the in-flight request instead
  /// of firing a duplicate RPC.
  Future<void> hydrateForMessages(String chatId, List<Message> messages) async {
    final id = chatId.trim();
    if (id.isEmpty) return;
    await _ensureSnapshotLoaded(id);

    final items = <_PendingItem>[];
    final seen = <String>{};
    for (final m in messages) {
      final kind = (m.cardKind ?? '').trim();
      final entityId = (m.cardEntityId ?? '').trim();
      if (kind.isEmpty || entityId.isEmpty) continue;
      final key = cacheKeyFor(kind, entityId);
      if (!seen.add(key)) continue;
      items.add(_PendingItem(
        kind: kind,
        entityId: entityId,
        cardMessageId: _looksLikeUuid(m.id) ? m.id : null,
      ));
      trackEntity(id, kind, entityId);
      if (items.length >= 50) break;
    }
    if (items.isEmpty) return;

    final existing = _inFlightHydrate[id];
    if (existing != null) {
      await existing;
      return;
    }
    final future = _hydrateBatch(id, items);
    _inFlightHydrate[id] = future;
    try {
      await future;
    } finally {
      _inFlightHydrate.remove(id);
    }
  }

  /// Per-card fallback lookup. Coalesces every call made within the same
  /// microtask tick (i.e. one build/frame across sibling cards) into a
  /// single batch RPC, so N simultaneously-mounting cards still cost one
  /// network round trip.
  Future<ChatActionCardEntry?> ensureLoaded(
    String chatId, {
    required String kind,
    required String entityId,
    String? cardMessageId,
    bool forceNetwork = false,
  }) async {
    final id = chatId.trim();
    final key = cacheKeyFor(kind, entityId);
    if (id.isEmpty || entityId.isEmpty) return _memory[key];
    await _ensureSnapshotLoaded(id);
    final cached = _memory[key];
    if (cached != null && !forceNetwork) return cached;
    if (forceNetwork) {
      _memory.remove(key);
    }

    final completer = Completer<ChatActionCardEntry?>();
    _pendingItems.putIfAbsent(id, () => []).add(
          _PendingItem(
            kind: kind,
            entityId: entityId,
            cardMessageId: cardMessageId,
          ),
        );
    _pendingCompleters.putIfAbsent(id, () => []).add(completer);

    if (_flushScheduled[id] != true) {
      _flushScheduled[id] = true;
      scheduleMicrotask(() => _flushPending(id));
    }
    return completer.future;
  }

  Future<void> _flushPending(String chatId) async {
    _flushScheduled[chatId] = false;
    final items = _pendingItems.remove(chatId) ?? const [];
    final completers = _pendingCompleters.remove(chatId) ?? const [];
    if (items.isEmpty) {
      for (final c in completers) {
        if (!c.isCompleted) c.complete(null);
      }
      return;
    }

    final deduped = <String, _PendingItem>{};
    for (final item in items) {
      deduped[cacheKeyFor(item.kind, item.entityId)] = item;
    }

    try {
      await _hydrateBatch(chatId, deduped.values.toList());
    } catch (_) {
      // _hydrateBatch already fails open (keeps/uses fallback); nothing more
      // to do here besides resolving completers below with best-effort data.
    }

    for (var i = 0; i < items.length; i++) {
      final key = cacheKeyFor(items[i].kind, items[i].entityId);
      final completer = completers[i];
      if (!completer.isCompleted) completer.complete(_memory[key]);
    }
  }

  Future<void> _hydrateBatch(String chatId, List<_PendingItem> items) async {
    try {
      final res = await _client.rpc(
        'get_chat_action_cards_batch',
        params: {
          'p_chat_id': chatId,
          'p_items': items
              .map((e) => {
                    'kind': e.kind,
                    'entity_id': e.entityId,
                    if (e.cardMessageId != null)
                      'card_message_id': e.cardMessageId,
                  })
              .toList(),
        },
      );
      final rows = _asList(res);
      for (final row in rows) {
        final entry = ChatActionCardEntry.fromBatchJson(row);
        if (entry == null) continue;
        _memory[cacheKeyFor(entry.kind, entry.entityId)] = entry;
      }
      await _persistSnapshot(chatId);
    } catch (e) {
      if (_isMissingRpc(e)) {
        await _fallbackLoad(chatId, items);
        return;
      }
      // Network/server error: keep whatever is already cached/persisted
      // (fail open) rather than tombstoning good last-known data.
    }
  }

  Future<void> _fallbackLoad(String chatId, List<_PendingItem> items) async {
    final needsTopics = items.any(
      (e) => canonicalKind(e.kind) == ChatActionCardKind.topicSelection,
    );
    final needsCollections = items.any(
      (e) => canonicalKind(e.kind) == ChatActionCardKind.groupCollection,
    );

    if (needsTopics) {
      try {
        final repo = ChatGroupActionsRepository(client: _client);
        final selections =
            await repo.listTopicSelectionsForChat(chatId, cacheFirst: true);
        for (final s in selections) {
          _memory[cacheKeyFor(ChatActionCardKind.topicSelection, s.id)] =
              ChatActionCardEntry.fromTopicSelection(s);
        }
      } catch (_) {}
    }

    if (needsCollections) {
      try {
        final res = await _client.rpc('list_group_collections');
        if (res is List) {
          for (final row in res) {
            if (row is! Map) continue;
            final map = Map<String, dynamic>.from(row);
            final id = (map['id'] ?? '').toString();
            if (id.isEmpty) continue;
            _memory[cacheKeyFor(ChatActionCardKind.groupCollection, id)] =
                ChatActionCardEntry.fromLegacyCollectionJson(map);
          }
        }
      } catch (_) {}
    }

    await _persistSnapshot(chatId);
  }

  bool _isMissingRpc(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('pgrst202') ||
        text.contains('could not find the function') ||
        text.contains('404');
  }

  String _snapshotKey(String chatId) =>
      '$_cachePrefix${_userId ?? 'anon'}:$chatId';

  Future<void> _ensureSnapshotLoaded(String chatId) async {
    if (_loadedSnapshotChats.contains(chatId)) return;
    _loadedSnapshotChats.add(chatId);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_snapshotKey(chatId));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is! Map) return;
        final entry =
            ChatActionCardEntry.fromCacheJson(Map<String, dynamic>.from(value));
        if (entry != null) {
          _memory.putIfAbsent(key.toString(), () => entry);
        }
      });
    } catch (_) {}
  }

  Future<void> _persistSnapshot(String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{};
      _memory.forEach((key, entry) {
        if (key.contains(':') && entry.available) {
          map[key] = entry.toCacheJson();
        }
      });
      await prefs.setString(_snapshotKey(chatId), jsonEncode(map));
    } catch (_) {}
  }

  static bool _looksLikeUuid(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(v);
  }

  List<Map<String, dynamic>> _asList(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Object>()
          .map((e) {
            if (e is Map<String, dynamic>) return e;
            if (e is Map) return Map<String, dynamic>.from(e);
            return <String, dynamic>{};
          })
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        return _asList(jsonDecode(raw));
      } catch (_) {}
    }
    return const [];
  }
}
