import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of dual-read Home promo load.
///
/// Remote Stage 14 migration may be absent: undefined RPC → demo fallback.
/// Successful empty list must NOT resurrect demo (Stage 14.1).
class HomePromoLoadResult {
  const HomePromoLoadResult({
    this.card,
    this.isDemoFallback = false,
    this.rpcUnavailable = false,
    this.intentionallyEmpty = false,
    this.loadError = false,
  });

  final ManagedContentCard? card;
  final bool isDemoFallback;
  final bool rpcUnavailable;

  /// Server answered successfully with no visible promo for this user.
  final bool intentionallyEmpty;

  /// Hard load failure (not missing RPC). Prefer last-good cache in UI.
  final bool loadError;

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

/// Cache-first Home promo reader + dismiss.
class HomePromoService {
  HomePromoService({
    HomePromoRpcClient? rpcClient,
    Future<SharedPreferences> Function()? prefs,
  })  : _rpc = rpcClient ?? SupabaseHomePromoRpcClient(),
        _prefs = prefs ?? SharedPreferences.getInstance;

  final HomePromoRpcClient _rpc;
  final Future<SharedPreferences> Function() _prefs;

  static const String cacheKey = 'home_promo_placement_v1';

  Future<HomePromoLoadResult> loadCached() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(cacheKey);
      if (raw == null || raw.isEmpty) {
        return const HomePromoLoadResult(isDemoFallback: true);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const HomePromoLoadResult(isDemoFallback: true);
      }
      final row = Map<String, dynamic>.from(decoded);
      final card = ManagedContentCard.tryParseHomePromo(row);
      if (card == null) {
        return const HomePromoLoadResult(isDemoFallback: true);
      }
      return HomePromoLoadResult(card: card);
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
        // Successful empty: do not resurrect hardcoded demo (14.1).
        if (writeCache) await _clearCache();
        return const HomePromoLoadResult(intentionallyEmpty: true);
      }

      Map<String, dynamic>? matchedRow;
      ManagedContentCard? matched;
      for (final row in rows) {
        final card = ManagedContentCard.tryParseHomePromo(row);
        if (card != null) {
          matched = card;
          matchedRow = row;
          break;
        }
      }
      if (matched == null || matchedRow == null) {
        // RPC answered but payload unusable — hide strip; do not fake live demo.
        if (writeCache) await _clearCache();
        return const HomePromoLoadResult(intentionallyEmpty: true);
      }
      if (writeCache) await _writeCache(matchedRow);
      return HomePromoLoadResult(card: matched);
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

  /// Nonfatal impression/click for managed cards only.
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

  Future<void> _writeCache(Map<String, dynamic> row) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(cacheKey, jsonEncode(row));
    } catch (e) {
      debugPrint('[home] promo cache write failed: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(cacheKey);
    } catch (_) {}
  }

  /// Only undefined-function / missing RPC signatures — not auth/RLS/DB errors.
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
