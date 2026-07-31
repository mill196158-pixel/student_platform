import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of dual-read Home promo load (Stage 14.1.4 multi-slot).
///
/// Remote Stage 14 migration may be absent: undefined RPC → demo fallback.
/// Successful empty list must NOT resurrect demo (Stage 14.1).
class HomePromoLoadResult {
  const HomePromoLoadResult({
    this.cards = const [],
    this.isDemoFallback = false,
    this.rpcUnavailable = false,
    this.intentionallyEmpty = false,
    this.loadError = false,
  });

  /// Ordered managed promos preserving server/list order and home_slot.
  final List<ManagedContentCard> cards;
  final bool isDemoFallback;
  final bool rpcUnavailable;

  /// Server answered successfully with no visible promo for this user.
  final bool intentionallyEmpty;

  /// Hard load failure (not missing RPC). Prefer last-good cache in UI.
  final bool loadError;

  /// First card for backward-compatible single-slot call sites.
  ManagedContentCard? get card => cards.isEmpty ? null : cards.first;

  HomePromoPayload get payload =>
      card?.homePromo ?? HomePromoPayload.demoStuckWithAssignment;

  bool get showDemoBadge =>
      isDemoFallback || (card != null && card!.showDemoBadge);

  bool get hidePromoStrip => intentionallyEmpty && !isDemoFallback;
}

/// Thin RPC boundary for tests.
abstract class HomePromoRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseHomePromoRpcClient implements HomePromoRpcClient {
  SupabaseHomePromoRpcClient([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _client.rpc(function, params: params);
  }
}

/// Cache-first Home promo reader + dismiss (multi-slot aware).
class HomePromoService {
  HomePromoService({
    HomePromoRpcClient? rpcClient,
    Future<SharedPreferences> Function()? prefs,
  })  : _rpc = rpcClient ?? SupabaseHomePromoRpcClient(),
        _prefs = prefs ?? SharedPreferences.getInstance;

  final HomePromoRpcClient _rpc;
  final Future<SharedPreferences> Function() _prefs;

  static const String cacheKey = 'home_promo_placements_v2';
  static const String legacyCacheKey = 'home_promo_placement_v1';

  Future<HomePromoLoadResult> loadCached() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(cacheKey) ?? prefs.getString(legacyCacheKey);
      if (raw == null || raw.isEmpty) {
        return const HomePromoLoadResult(isDemoFallback: true);
      }
      final decoded = jsonDecode(raw);
      final cards = <ManagedContentCard>[];
      if (decoded is List) {
        for (final row in decoded.whereType<Map>()) {
          final card = ManagedContentCard.tryParseHomePromo(
            Map<String, dynamic>.from(row),
          );
          if (card != null) cards.add(card);
        }
      } else if (decoded is Map) {
        final card = ManagedContentCard.tryParseHomePromo(
          Map<String, dynamic>.from(decoded),
        );
        if (card != null) cards.add(card);
      }
      if (cards.isEmpty) {
        return const HomePromoLoadResult(isDemoFallback: true);
      }
      return HomePromoLoadResult(cards: cards);
    } catch (e) {
      debugPrint('[home] promo cache read failed: $e');
      return const HomePromoLoadResult(isDemoFallback: true);
    }
  }

  Future<HomePromoLoadResult> load({bool writeCache = true}) async {
    try {
      final response = await _rpc.rpc(
        'get_my_content_for_placement',
        params: {'p_placement': 'home_promo'},
      );
      final rows = _asList(response);
      if (rows.isEmpty) {
        if (writeCache) await _clearCache();
        return const HomePromoLoadResult(intentionallyEmpty: true);
      }

      final cards = <ManagedContentCard>[];
      final matchedRows = <Map<String, dynamic>>[];
      for (final row in rows) {
        final card = ManagedContentCard.tryParseHomePromo(row);
        if (card != null) {
          cards.add(card);
          matchedRows.add(row);
        }
      }
      if (cards.isEmpty) {
        if (writeCache) await _clearCache();
        return const HomePromoLoadResult(intentionallyEmpty: true);
      }
      if (writeCache) await _writeCache(matchedRows);
      return HomePromoLoadResult(cards: cards);
    } on PostgrestException catch (error) {
      if (_isMissingRpc(error)) {
        return const HomePromoLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    } catch (error) {
      if (_isMissingRpcMessage(error.toString())) {
        return const HomePromoLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    }
  }

  Future<void> dismiss(String contentItemId) async {
    await _rpc.rpc(
      'dismiss_content_item',
      params: {'p_id': contentItemId},
    );
    await _clearCache();
  }

  Future<void> recordEvent(String contentItemId, String eventType) async {
    try {
      await _rpc.rpc(
        'record_content_event',
        params: {'p_id': contentItemId, 'p_event': eventType},
      );
    } catch (error) {
      debugPrint('[home] promo event $eventType failed: $error');
    }
  }

  Future<void> _writeCache(List<Map<String, dynamic>> rows) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(cacheKey, jsonEncode(rows));
      await prefs.remove(legacyCacheKey);
    } catch (e) {
      debugPrint('[home] promo cache write failed: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(cacheKey);
      await prefs.remove(legacyCacheKey);
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
