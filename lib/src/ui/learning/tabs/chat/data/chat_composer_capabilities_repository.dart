import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_composer_capabilities.dart';

/// Loads/caches `get_chat_composer_capabilities`.
///
/// Last successful result is keyed by userId + chatId and is never cleared by
/// a transient network error (fail-open on cache, fail-closed only when unknown).
class ChatComposerCapabilitiesRepository {
  ChatComposerCapabilitiesRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;
  static const _cachePrefix = 'chat_composer_caps_v2:';

  String? get _userId => _client.auth.currentUser?.id;

  String _cacheKey(String chatId) =>
      '$_cachePrefix${_userId ?? 'anon'}:$chatId';

  Future<ChatComposerCapabilities> load(
    String chatId, {
    String? fallbackTeamKind,
    bool isDm = false,
    bool? localIsOrganizer,
  }) async {
    final kind = isDm ? 'dm' : (fallbackTeamKind ?? 'subject');
    if (chatId.isEmpty) {
      return ChatComposerCapabilities.structuralLoading(
        teamKind: kind,
        isDm: isDm,
      );
    }

    final cached = await peekCache(chatId);

    try {
      final res = await _client.rpc(
        'get_chat_composer_capabilities',
        params: {'p_chat_id': chatId},
      );
      final map = _asMap(res);
      if (map.isEmpty) {
        throw StateError('empty_capabilities');
      }
      final caps = ChatComposerCapabilities.fromJson(map);
      await _writeCache(chatId, caps.toJson());
      return caps;
    } catch (e) {
      // Prefer last successful capabilities — do not flip can_* to false.
      if (cached != null) {
        return cached.copyWith(fromCache: true, loading: false);
      }
      if (_isMissingRpc(e)) {
        // Pre-13.11 remote: membership creation for structural kinds.
        return _membershipFallback(
          teamKind: kind,
          isDm: isDm,
          isOrganizer: localIsOrganizer ?? false,
        );
      }
      return ChatComposerCapabilities.structuralLoading(
        teamKind: kind,
        isDm: isDm,
      ).copyWith(loading: true);
    }
  }

  bool _isMissingRpc(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('pgrst202') ||
        text.contains('could not find the function') ||
        (text.contains('get_chat_composer_capabilities') &&
            (text.contains('404') || text.contains('not find')));
  }

  /// Compatibility when RPC missing: creation by membership, not organizer.
  ChatComposerCapabilities _membershipFallback({
    required String teamKind,
    required bool isDm,
    required bool isOrganizer,
  }) {
    final showPropose = ChatComposerCapabilities.showProposeForKind(isDm: isDm);
    final showTopic = ChatComposerCapabilities.showTopicForKind(
      isDm: isDm,
      teamKind: teamKind,
    );
    final showCollection = ChatComposerCapabilities.showCollectionForKind(
      isDm: isDm,
      teamKind: teamKind,
    );
    return ChatComposerCapabilities(
      chatType: isDm ? 'dm' : 'team',
      teamKind: isDm ? 'dm' : teamKind,
      isActiveMember: true,
      isActiveSubjectTeam: teamKind == 'subject',
      showProposeAssignment: showPropose,
      showTopicSelection: showTopic,
      showCollection: showCollection,
      canProposeAssignment: showPropose,
      canManageAssignments: isOrganizer,
      canCreateAssignment: showPropose,
      canCreateTopicSelection: showTopic,
      canCreateCollection: showCollection,
      canEditOwnBeforeActivity: showPropose,
      canModerateTopicSelection: showTopic && isOrganizer,
      canModerateCollection: showCollection && isOrganizer,
      canManageCollectionReceipts: showCollection && isOrganizer,
      canDeleteGroupAction: isOrganizer && (showTopic || showCollection),
      reasons: {
        'propose_assignment': showPropose ? null : 'dm_not_allowed',
        'topic_selection': !showTopic
            ? (teamKind == 'group_space'
                ? 'group_space_not_allowed'
                : 'dm_not_allowed')
            : null,
        'collection': !showCollection
            ? (isDm ? 'dm_not_allowed' : 'subject_not_allowed')
            : null,
      },
    );
  }

  Future<ChatComposerCapabilities?> peekCache(String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(chatId));
      if (raw == null || raw.isEmpty) {
        // Migrate v1 cache (chatId-only) once if present.
        final legacy = prefs.getString('chat_composer_caps_v1:$chatId');
        if (legacy == null || legacy.isEmpty) return null;
        final map = Map<String, dynamic>.from(jsonDecode(legacy) as Map);
        final caps = ChatComposerCapabilities.fromJson(map);
        await _writeCache(chatId, caps.toJson());
        return caps.copyWith(fromCache: true);
      }
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return ChatComposerCapabilities.fromJson(map).copyWith(fromCache: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String chatId, Map<String, dynamic> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey(chatId), jsonEncode(map));
    } catch (_) {}
  }

  Map<String, dynamic> _asMap(dynamic res) {
    if (res is Map<String, dynamic>) return res;
    if (res is Map) return Map<String, dynamic>.from(res);
    return const {};
  }
}
