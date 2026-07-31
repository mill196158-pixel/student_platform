import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SubjectCardLoadResult {
  const SubjectCardLoadResult({
    this.card,
    this.fromCache = false,
    this.networkFailed = false,
    this.accessDenied = false,
  });

  final SubjectCardPayload? card;
  final bool fromCache;
  final bool networkFailed;
  final bool accessDenied;
}

/// Stage 16.1 mobile reader for merged subject card (via offering id).
///
/// Cache-first helpers support painting last-good content before refresh.
/// Cache fallback is only for transient/network errors; forbidden/not-found
/// and invalid successful responses clear the scoped entry (fail-closed).
class SubjectCardService {
  SubjectCardService({
    Future<dynamic> Function(String function, {Map<String, dynamic>? params})?
        rpc,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _rpc = rpc ??
            ((function, {params}) =>
                Supabase.instance.client.rpc(function, params: params)),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId ??
            (() => Supabase.instance.client.auth.currentUser?.id);

  final Future<dynamic> Function(
    String function, {
    Map<String, dynamic>? params,
  }) _rpc;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function() _currentUserId;

  static const String keyPrefix = 'subject_card_v1';

  String _key(String offeringId) {
    final user = (_currentUserId() ?? '').trim();
    final scope = user.isEmpty ? 'anon' : user;
    return '${keyPrefix}__${scope}__$offeringId';
  }

  Future<SubjectCardPayload?> loadCached(String subjectOfferingId) async {
    final id = subjectOfferingId.trim();
    if (id.isEmpty) return null;
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_key(id));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SubjectCardPayload.tryParse(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('[subject_card] cache read failed: $e');
      return null;
    }
  }

  Future<SubjectCardLoadResult> loadForOffering(
    String subjectOfferingId, {
    bool writeCache = true,
  }) async {
    final id = subjectOfferingId.trim();
    if (id.isEmpty) {
      return const SubjectCardLoadResult();
    }

    final cached = await loadCached(id);

    try {
      final response = await _rpc(
        'get_subject_card',
        params: {'p_subject_offering_id': id},
      );
      final map = _asMap(response);
      if (map == null) {
        await _clearOffering(id);
        return const SubjectCardLoadResult();
      }
      final card = SubjectCardPayload.tryParse(map);
      if (card == null) {
        await _clearOffering(id);
        return const SubjectCardLoadResult();
      }
      if (writeCache) {
        await _writeCache(id, map);
      }
      return SubjectCardLoadResult(card: card);
    } on PostgrestException catch (error) {
      debugPrint('[subject_card] load failed: $error');
      if (isMissingRpc(error)) rethrow;
      if (isAccessDenied(error)) {
        await _clearOffering(id);
        return const SubjectCardLoadResult(accessDenied: true);
      }
      if (cached != null && isTransient(error)) {
        return SubjectCardLoadResult(
          card: cached,
          fromCache: true,
          networkFailed: true,
        );
      }
      rethrow;
    } catch (error) {
      debugPrint('[subject_card] load failed: $error');
      if (cached != null && isTransientMessage(error.toString())) {
        return SubjectCardLoadResult(
          card: cached,
          fromCache: true,
          networkFailed: true,
        );
      }
      rethrow;
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

  Future<void> _clearOffering(String offeringId) async {
    try {
      final prefs = await _prefs();
      await prefs.remove(_key(offeringId));
    } catch (_) {}
  }

  Future<void> _writeCache(String offeringId, Map<String, dynamic> map) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(_key(offeringId), jsonEncode(map));
    } catch (e) {
      debugPrint('[subject_card] cache write failed: $e');
    }
  }

  static bool isMissingRpc(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == 'PGRST202' || code == '42883') return true;
    return isMissingRpcMessage(error.message);
  }

  static bool isMissingRpcMessage(String raw) {
    final message = raw.toLowerCase();
    return message.contains('get_subject_card') &&
        (message.contains('could not find') ||
            message.contains('does not exist') ||
            (message.contains('function') && message.contains('not exist')));
  }

  static bool isAccessDenied(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == '42501' || code == 'P0002' || code == '28000') {
      return true;
    }
    final message = error.message.toLowerCase();
    return message.contains('forbidden') ||
        message.contains('not_found') ||
        message.contains('not found') ||
        message.contains('jwt');
  }

  static bool isTransient(PostgrestException error) {
    if (isMissingRpc(error) || isAccessDenied(error)) return false;
    final code = (error.code ?? '').toUpperCase();
    if (code == '57014' ||
        code == '08006' ||
        code == '08001' ||
        code == '57P01') {
      return true;
    }
    return isTransientMessage(error.message);
  }

  static bool isTransientMessage(String raw) {
    final message = raw.toLowerCase();
    return message.contains('network') ||
        message.contains('timeout') ||
        message.contains('timed out') ||
        message.contains('connection') ||
        message.contains('unavailable') ||
        message.contains('socket');
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
