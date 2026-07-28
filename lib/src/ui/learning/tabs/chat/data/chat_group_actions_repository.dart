import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_group_actions.dart';

/// Cache-first chat-scoped topic/collection actions (Stage 13.9).
class ChatGroupActionsRepository {
  ChatGroupActionsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  static const _cachePrefix = 'chat_group_actions_v1_';
  static const _pendingPicksKey = 'chat_group_actions_pending_picks_v1';
  static const _deadlinesCachePrefix = 'chat_group_actions_deadlines_v1_';

  String? get _userId => _client.auth.currentUser?.id;

  String _selectionsCacheKey(String chatId) =>
      '$_cachePrefix${_userId ?? 'anon'}_selections_$chatId';

  Future<List<ChatTopicSelection>> peekCachedSelections(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_selectionsCacheKey(chatId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => ChatTopicSelection.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _storeCachedSelections(
    String chatId,
    List<ChatTopicSelection> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _selectionsCacheKey(chatId),
      jsonEncode(items
          .map((e) => {
                'id': e.id,
                'title': e.title,
                'description': e.description,
                'status': e.status,
                'allow_change': e.allowChange,
                'show_results_to_all': e.showResultsToAll,
                'deadline_at': e.deadlineAt?.toIso8601String(),
                'completion_deadline_at':
                    e.completionDeadlineAt?.toIso8601String(),
                'source_file_id': e.sourceFileId,
                'card_message_id': e.cardMessageId,
                'free_slots': e.freeSlots,
                'taken_slots': e.takenSlots,
                'total_capacity': e.totalCapacity,
              })
          .toList()),
    );
  }

  Future<List<ChatTopicSelection>> listTopicSelectionsForChat(
    String chatId, {
    bool cacheFirst = true,
  }) async {
    if (cacheFirst) {
      final cached = await peekCachedSelections(chatId);
      if (cached.isNotEmpty) {
        unawaited(_refreshSelections(chatId));
        return cached;
      }
    }
    return _refreshSelections(chatId);
  }

  Future<List<ChatTopicSelection>> _refreshSelections(String chatId) async {
    final res = await _client.rpc(
      'list_topic_selections_for_chat',
      params: {'p_chat_id': chatId},
    );
    final items = _asList(res).map(ChatTopicSelection.fromJson).toList();
    await _storeCachedSelections(chatId, items);
    return items;
  }

  Future<List<ChatTopicOption>> listTopicOptionsForSelection(
    String selectionId,
  ) async {
    final res = await _client.rpc(
      'list_topic_options_for_selection',
      params: {'p_selection_id': selectionId},
    );
    return _asList(res).map(ChatTopicOption.fromJson).toList();
  }

  Future<Map<String, dynamic>> publishTopicSelectionForChat({
    required String chatId,
    required String title,
    String description = '',
    DateTime? deadlineAt,
    DateTime? completionDeadlineAt,
    bool allowChange = true,
    bool showResultsToAll = true,
    String? sourceFileId,
    required List<TopicOptionDraft> options,
  }) async {
    final res = await _client.rpc(
      'publish_topic_selection_for_chat',
      params: {
        'p_chat_id': chatId,
        'p_title': title,
        'p_description': description,
        'p_deadline_at': deadlineAt?.toIso8601String(),
        'p_completion_deadline_at': completionDeadlineAt?.toIso8601String(),
        'p_allow_change': allowChange,
        'p_show_results_to_all': showResultsToAll,
        'p_source_file_id': sourceFileId,
        'p_options': options.map((e) => e.toJson()).toList(),
      },
    );
    await _refreshSelections(chatId);
    return _asMap(res) ?? const {};
  }

  Future<void> pickTopic({
    required String selectionId,
    required String optionId,
  }) async {
    await _enqueuePendingPick(selectionId, optionId);
    try {
      await _client.rpc(
        'pick_topic',
        params: {
          'p_selection_id': selectionId,
          'p_option_id': optionId,
        },
      );
      await _removePendingPick(selectionId, optionId);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> reassignTopicPick({
    required String selectionId,
    required String userId,
    required String optionId,
  }) {
    return _client.rpc(
      'reassign_topic_pick',
      params: {
        'p_selection_id': selectionId,
        'p_user_id': userId,
        'p_option_id': optionId,
      },
    );
  }

  Future<void> cancelTopicPick(String selectionId) async {
    await _client.rpc(
      'cancel_topic_pick',
      params: {'p_selection_id': selectionId},
    );
    final pending = await peekPendingPicks();
    final next =
        pending.where((e) => e['selection_id'] != selectionId).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingPicksKey, jsonEncode(next));
  }

  Future<String> createCollection({
    required String title,
    String description = '',
    String purpose = '',
    DateTime? deadlineAt,
    String amountMode = 'none',
    double? amountOptional,
    double? amountTotal,
    String instructions = '',
    String paymentDetails = '',
  }) async {
    final mode = amountMode.trim().toLowerCase();
    final id = await _client.rpc(
      'create_group_collection',
      params: {
        'p_title': title,
        'p_description': description,
        'p_purpose': purpose,
        'p_deadline_at': deadlineAt?.toIso8601String(),
        'p_amount_mode': mode.isEmpty ? 'none' : mode,
        'p_amount_optional': mode == 'per_person' ? amountOptional : null,
        'p_amount_total': mode == 'total' ? amountTotal : null,
        'p_instructions': instructions,
        'p_payment_details': paymentDetails,
      },
    );
    return id.toString();
  }

  Future<void> deleteGroupAction({
    required String kind,
    required String entityId,
  }) {
    return _client.rpc(
      'delete_group_action',
      params: {
        'p_kind': kind,
        'p_entity_id': entityId,
      },
    );
  }

  Future<void> updateTopicSelectionBeforeActivity({
    required String selectionId,
    String? title,
    String? description,
    DateTime? deadlineAt,
    bool? allowChange,
  }) {
    return _client.rpc(
      'update_topic_selection_before_activity',
      params: {
        'p_selection_id': selectionId,
        'p_title': title,
        'p_description': description,
        'p_deadline_at': deadlineAt?.toIso8601String(),
        'p_allow_change': allowChange,
      },
    );
  }

  Future<void> closeTopicSelection({
    required String selectionId,
    String status = 'closed',
  }) {
    return _client.rpc(
      'close_topic_selection',
      params: {
        'p_selection_id': selectionId,
        'p_status': status,
      },
    );
  }

  Future<List<GroupActionDeadline>> listMyGroupActionDeadlines({
    DateTime? from,
    DateTime? to,
  }) async {
    final res = await _client.rpc(
      'list_my_group_action_deadlines',
      params: {
        'p_from': from?.toIso8601String(),
        'p_to': to?.toIso8601String(),
      },
    );
    return _asList(res).map(GroupActionDeadline.fromJson).toList();
  }

  String _deadlinesCacheKey(DateTime? from, DateTime? to) {
    final user = _userId ?? 'anon';
    final fromKey = from?.toUtc().millisecondsSinceEpoch ?? 'null';
    final toKey = to?.toUtc().millisecondsSinceEpoch ?? 'null';
    return '$_deadlinesCachePrefix${user}_${fromKey}_$toKey';
  }

  Future<List<GroupActionDeadline>> listMyGroupActionDeadlinesCached({
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      final items = await listMyGroupActionDeadlines(from: from, to: to);
      await _storeCachedDeadlines(from, to, items);
      return items;
    } catch (_) {
      return peekCachedDeadlines(from: from, to: to);
    }
  }

  Future<List<GroupActionDeadline>> peekCachedDeadlines({
    DateTime? from,
    DateTime? to,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_deadlinesCacheKey(from, to));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
              (e) => GroupActionDeadline.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _storeCachedDeadlines(
    DateTime? from,
    DateTime? to,
    List<GroupActionDeadline> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _deadlinesCacheKey(from, to),
      jsonEncode(items
          .map((e) => {
                'event_type': e.eventType,
                'entity_id': e.entityId,
                'title': e.title,
                'occurs_at': e.occursAt.toIso8601String(),
                'chat_id': e.chatId,
                'team_id': e.teamId,
                'group_id': e.groupId,
                'team_name': e.teamName,
                'status': e.status,
                'my_pick_text': e.myPickText,
                'payload': {
                  if (e.cardMessageId != null)
                    'card_message_id': e.cardMessageId,
                },
              })
          .toList()),
    );
  }

  Future<List<Map<String, String>>> peekPendingPicks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingPicksKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => {
                'selection_id': (e['selection_id'] ?? '').toString(),
                'option_id': (e['option_id'] ?? '').toString(),
              })
          .where((e) =>
              e['selection_id']!.isNotEmpty && e['option_id']!.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> flushPendingPicks() async {
    final pending = await peekPendingPicks();
    for (final item in pending) {
      try {
        await _client.rpc(
          'pick_topic',
          params: {
            'p_selection_id': item['selection_id'],
            'p_option_id': item['option_id'],
          },
        );
        await _removePendingPick(
          item['selection_id']!,
          item['option_id']!,
        );
      } catch (_) {
        // Keep in queue until server confirms.
      }
    }
  }

  Future<void> _enqueuePendingPick(String selectionId, String optionId) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = await peekPendingPicks();
    final next = [
      ...pending.where((e) => e['selection_id'] != selectionId),
      {'selection_id': selectionId, 'option_id': optionId},
    ];
    await prefs.setString(_pendingPicksKey, jsonEncode(next));
  }

  Future<void> _removePendingPick(String selectionId, String optionId) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = await peekPendingPicks();
    final next = pending
        .where((e) =>
            e['selection_id'] != selectionId || e['option_id'] != optionId)
        .toList();
    await prefs.setString(_pendingPicksKey, jsonEncode(next));
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

  Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        return _asMap(decoded);
      } catch (_) {}
    }
    return null;
  }
}
