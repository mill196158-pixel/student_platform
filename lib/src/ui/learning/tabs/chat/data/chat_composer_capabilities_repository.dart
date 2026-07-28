import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_composer_capabilities.dart';

/// Loads/caches `get_chat_composer_capabilities` with fail-closed auth.
class ChatComposerCapabilitiesRepository {
  ChatComposerCapabilitiesRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;
  static const _cachePrefix = 'chat_composer_caps_v1:';

  Future<ChatComposerCapabilities> load(
    String chatId, {
    String? fallbackTeamKind,
    bool isDm = false,
    bool? localIsOrganizer,
  }) async {
    final kind = isDm ? 'dm' : (fallbackTeamKind ?? 'subject');
    if (chatId.isEmpty) {
      return _structuralOnly(teamKind: kind, isDm: isDm);
    }

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
      await _writeCache(chatId, map);
      return caps;
    } catch (e) {
      // Compatibility only while Stage 13.10 RPC is not applied remotely.
      if (_isMissingRpc(e)) {
        return _compatFallback(
          teamKind: kind,
          isDm: isDm,
          isOrganizer: localIsOrganizer ?? false,
        );
      }
      // Fail-closed authorization; keep structural show_* for stable menu.
      final cached = await peekCache(chatId);
      return _structuralOnly(
        teamKind: cached?.teamKind ?? kind,
        isDm: isDm || (cached?.isDm ?? false),
        fromCache: cached != null,
      );
    }
  }

  bool _isMissingRpc(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('pgrst202') ||
        text.contains('could not find the function') ||
        text.contains('get_chat_composer_capabilities') &&
            (text.contains('404') || text.contains('not find'));
  }

  /// Structural visibility only — all can_* false (fail-closed).
  ChatComposerCapabilities _structuralOnly({
    required String teamKind,
    required bool isDm,
    bool fromCache = false,
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
      isActiveMember: false,
      isActiveSubjectTeam: false,
      showProposeAssignment: showPropose,
      showTopicSelection: showTopic,
      showCollection: showCollection,
      canProposeAssignment: false,
      canManageAssignments: false,
      canCreateTopicSelection: false,
      canCreateCollection: false,
      reasons: const {
        'propose_assignment': 'permissions_unavailable',
        'topic_selection': 'permissions_unavailable',
        'collection': 'permissions_unavailable',
      },
      fromCache: fromCache,
    );
  }

  /// Pre-migration compatibility: structural + local role guess.
  ChatComposerCapabilities _compatFallback({
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
      canCreateTopicSelection: showTopic && isOrganizer,
      canCreateCollection: showCollection && isOrganizer,
      reasons: {
        'propose_assignment': showPropose ? null : 'dm_not_allowed',
        'topic_selection': !showTopic
            ? (teamKind == 'group_space'
                ? 'group_space_not_allowed'
                : 'dm_not_allowed')
            : (isOrganizer ? null : 'not_organizer'),
        'collection': !showCollection
            ? (isDm ? 'dm_not_allowed' : 'subject_not_allowed')
            : (isOrganizer ? null : 'not_organizer'),
      },
    );
  }

  Future<ChatComposerCapabilities?> peekCache(String chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_cachePrefix$chatId');
      if (raw == null || raw.isEmpty) return null;
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return ChatComposerCapabilities.fromJson(map).copyWith(fromCache: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String chatId, Map<String, dynamic> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_cachePrefix$chatId', jsonEncode(map));
    } catch (_) {}
  }

  Map<String, dynamic> _asMap(dynamic res) {
    if (res is Map<String, dynamic>) return res;
    if (res is Map) return Map<String, dynamic>.from(res);
    return const {};
  }
}
