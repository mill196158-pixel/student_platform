import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileFeedLoadResult {
  const ProfileFeedLoadResult({
    this.cards = const [],
    this.isDemoFallback = false,
    this.rpcUnavailable = false,
    this.intentionallyEmpty = false,
    this.loadError = false,
  });

  final List<ManagedProfileFeedCard> cards;
  final bool isDemoFallback;
  final bool rpcUnavailable;
  final bool intentionallyEmpty;
  final bool loadError;

  /// Successful empty response only — never hide on hard error.
  bool get hideFeed =>
      intentionallyEmpty && !isDemoFallback && !loadError;

  bool get showLoadError => loadError && cards.isEmpty && !isDemoFallback;

  List<ManagedProfileFeedCard> get displayCards {
    if (hideFeed || showLoadError) return const [];
    if (isDemoFallback || cards.isEmpty) {
      return [
        for (var i = 0; i < ProfileFeedPayload.demoFeed.length; i++)
          ManagedProfileFeedCard(
            id: 'demo-profile-feed-$i',
            origin: ContentOrigin.demo,
            sortOrder: i,
            priority: 0,
            payload: ProfileFeedPayload.demoFeed[i],
            showDemoBadge: true,
          ),
      ];
    }
    return cards;
  }
}

abstract class ProfileFeedRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseProfileFeedRpcClient implements ProfileFeedRpcClient {
  SupabaseProfileFeedRpcClient([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

class ProfileFeedService {
  ProfileFeedService({
    ProfileFeedRpcClient? rpcClient,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _rpc = rpcClient ?? SupabaseProfileFeedRpcClient(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId ??
            (() => Supabase.instance.client.auth.currentUser?.id);

  final ProfileFeedRpcClient _rpc;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function() _currentUserId;

  static const String keyPrefix = 'profile_feed_placement_v1';

  String _key() {
    final id = (_currentUserId() ?? '').trim();
    return id.isEmpty ? '${keyPrefix}__anon' : '${keyPrefix}__$id';
  }

  Future<ProfileFeedLoadResult> loadCached() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_key());
      if (raw == null || raw.isEmpty) {
        return const ProfileFeedLoadResult(isDemoFallback: true);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const ProfileFeedLoadResult(isDemoFallback: true);
      }
      final cards = <ManagedProfileFeedCard>[];
      for (final row in decoded.whereType<Map>()) {
        final card = ManagedProfileFeedCard.tryParse(
          Map<String, dynamic>.from(row),
        );
        if (card != null) cards.add(card);
      }
      if (cards.isEmpty) {
        return const ProfileFeedLoadResult(isDemoFallback: true);
      }
      return ProfileFeedLoadResult(cards: cards);
    } catch (e) {
      debugPrint('[profile] feed cache read failed: $e');
      return const ProfileFeedLoadResult(isDemoFallback: true);
    }
  }

  Future<ProfileFeedLoadResult> load({bool writeCache = true}) async {
    try {
      final response = await _rpc.rpc(
        'get_my_content_for_placement',
        params: {'p_placement': 'profile_feed'},
      );
      final rows = _asList(response);
      if (rows.isEmpty) {
        if (writeCache) await _clearCache();
        return const ProfileFeedLoadResult(intentionallyEmpty: true);
      }
      final matchedRows = <Map<String, dynamic>>[];
      final cards = <ManagedProfileFeedCard>[];
      for (final row in rows) {
        final card = ManagedProfileFeedCard.tryParse(row);
        if (card == null) continue;
        cards.add(card);
        matchedRows.add(row);
      }
      if (cards.isEmpty) {
        if (writeCache) await _clearCache();
        return const ProfileFeedLoadResult(intentionallyEmpty: true);
      }
      if (writeCache) await _writeCache(matchedRows);
      return ProfileFeedLoadResult(cards: cards);
    } on PostgrestException catch (error) {
      if (_isMissingRpc(error)) {
        return const ProfileFeedLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    } catch (error) {
      if (_isMissingRpcMessage(error.toString())) {
        return const ProfileFeedLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    }
  }

  Future<void> recordEvent(String contentItemId, String eventType) async {
    try {
      await _rpc.rpc(
        'record_content_event',
        params: {'p_id': contentItemId, 'p_event': eventType},
      );
    } catch (error) {
      debugPrint('[profile] feed event $eventType failed: $error');
    }
  }

  Future<void> clearAll() async {
    try {
      final prefs = await _prefs();
      for (final key in prefs.getKeys().where((k) => k.startsWith(keyPrefix))) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  Future<void> _writeCache(List<Map<String, dynamic>> rows) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(_key(), jsonEncode(rows));
    } catch (e) {
      debugPrint('[profile] feed cache write failed: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(_key());
    } catch (_) {}
  }

  bool _isMissingRpc(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == 'PGRST202' || code == '42883') return true;
    return _isMissingRpcMessage(error.message);
  }

  bool _isMissingRpcMessage(String raw) {
    final message = raw.toLowerCase();
    final namesFunction = message.contains('get_my_content_for_placement');
    final missingPhrase = message.contains('could not find the function') ||
        message.contains('does not exist') ||
        message.contains('undefined_function') ||
        message.contains('undefined function');
    return missingPhrase && namesFunction;
  }

  List<Map<String, dynamic>> _asList(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const [];
      }
    }
    if (value is List) {
      return value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }
}
