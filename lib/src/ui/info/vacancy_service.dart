import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VacancyLoadResult {
  const VacancyLoadResult({
    this.cards = const [],
    this.isDemoFallback = false,
    this.rpcUnavailable = false,
    this.intentionallyEmpty = false,
    this.loadError = false,
  });

  final List<ManagedVacancyCard> cards;
  final bool isDemoFallback;
  final bool rpcUnavailable;
  final bool intentionallyEmpty;
  final bool loadError;

  /// Successful empty response only — never hide on hard error.
  bool get hideVacancies =>
      intentionallyEmpty && !isDemoFallback && !loadError;

  bool get showLoadError => loadError && cards.isEmpty && !isDemoFallback;

  List<ManagedVacancyCard> get displayCards {
    if (hideVacancies || showLoadError) return const [];
    if (isDemoFallback || cards.isEmpty) {
      return [
        for (var i = 0; i < VacancyCardPayload.demoVacancies.length; i++)
          ManagedVacancyCard(
            id: 'demo-vacancy-$i',
            origin: ContentOrigin.demo,
            payload: VacancyCardPayload.demoVacancies[i],
            showDemoBadge: true,
          ),
      ];
    }
    return cards;
  }
}

abstract class VacancyRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseVacancyRpcClient implements VacancyRpcClient {
  SupabaseVacancyRpcClient([SupabaseClient? client]) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _resolvedClient => _client ?? Supabase.instance.client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _resolvedClient.rpc(function, params: params);
  }
}

/// Mobile vacancies loader — RPC `get_my_vacancies` with dual-read fallback.
///
/// Missing RPC → labeled demo (`Пример`). Empty `[]` ≠ demo.
class VacancyService {
  VacancyService({
    VacancyRpcClient? rpcClient,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _rpc = rpcClient ?? SupabaseVacancyRpcClient(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId ??
            (() => Supabase.instance.client.auth.currentUser?.id);

  final VacancyRpcClient _rpc;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function() _currentUserId;

  static const String keyPrefix = 'vacancies_v1';

  /// Persisted when RPC returns successful empty — prevents demo resurrection.
  static const String emptyCacheSentinel = '__intentionally_empty_v1';

  String _key() {
    final id = (_currentUserId() ?? '').trim();
    return id.isEmpty ? '${keyPrefix}__anon' : '${keyPrefix}__$id';
  }

  Future<VacancyLoadResult> loadCached() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_key());
      if (raw == null || raw.isEmpty) {
        return const VacancyLoadResult(isDemoFallback: true);
      }
      if (raw == emptyCacheSentinel) {
        return const VacancyLoadResult(intentionallyEmpty: true);
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['__intentionally_empty'] == true) {
        return const VacancyLoadResult(intentionallyEmpty: true);
      }
      if (decoded is! List) {
        return const VacancyLoadResult(isDemoFallback: true);
      }
      final cards = <ManagedVacancyCard>[];
      for (final row in decoded.whereType<Map>()) {
        final card = ManagedVacancyCard.tryParse(
          Map<String, dynamic>.from(row),
        );
        if (card != null) cards.add(card);
      }
      if (cards.isEmpty) {
        return const VacancyLoadResult(isDemoFallback: true);
      }
      return VacancyLoadResult(cards: cards);
    } catch (e) {
      debugPrint('[vacancies] cache read failed: $e');
      return const VacancyLoadResult(isDemoFallback: true);
    }
  }

  Future<VacancyLoadResult> load({bool writeCache = true}) async {
    try {
      final response = await _rpc.rpc('get_my_vacancies');
      final rows = _asList(response);
      if (rows.isEmpty) {
        if (writeCache) await _writeEmptyCache();
        return const VacancyLoadResult(intentionallyEmpty: true);
      }
      final matchedRows = <Map<String, dynamic>>[];
      final cards = <ManagedVacancyCard>[];
      for (final row in rows) {
        final card = ManagedVacancyCard.tryParse(row);
        if (card == null) continue;
        cards.add(card);
        matchedRows.add(row);
      }
      if (cards.isEmpty) {
        if (writeCache) await _writeEmptyCache();
        return const VacancyLoadResult(intentionallyEmpty: true);
      }
      if (writeCache) await _writeCache(matchedRows);
      return VacancyLoadResult(cards: cards);
    } on PostgrestException catch (error) {
      if (_isMissingRpc(error)) {
        return const VacancyLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    } catch (error) {
      if (_isMissingRpcMessage(error.toString())) {
        return const VacancyLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    }
  }

  /// Protected contacts for a published+visible vacancy (`get_vacancy_contacts`).
  Future<VacancyContacts?> fetchContacts(String vacancyId) async {
    try {
      final response = await _rpc.rpc(
        'get_vacancy_contacts',
        params: {'p_id': vacancyId},
      );
      final map = _asMap(response);
      if (map == null) return null;
      final contacts = map['contacts'];
      if (contacts is Map) {
        return VacancyContacts.fromJson(Map<String, dynamic>.from(contacts));
      }
      return const VacancyContacts();
    } on PostgrestException catch (error) {
      if (error.code == 'P0002' || error.code == '42501') return null;
      rethrow;
    }
  }

  Future<void> reportVacancy({
    required String vacancyId,
    required VacancyReportReason reason,
    String? note,
  }) async {
    await _rpc.rpc(
      'report_vacancy',
      params: {
        'p_vacancy_id': vacancyId,
        'p_reason_code': reason.wireValue,
        'p_note': note,
      },
    );
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
      debugPrint('[vacancies] cache write failed: $e');
    }
  }

  Future<void> _writeEmptyCache() async {
    try {
      final prefs = await _prefs();
      await prefs.setString(_key(), emptyCacheSentinel);
    } catch (e) {
      debugPrint('[vacancies] empty cache write failed: $e');
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
    final namesFunction = message.contains('get_my_vacancies');
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

  Map<String, dynamic>? _asMap(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}
