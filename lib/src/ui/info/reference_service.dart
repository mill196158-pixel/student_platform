import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of dual-read reference bundle load.
class ReferenceLoadResult {
  const ReferenceLoadResult({
    this.bundle,
    this.isDemoFallback = false,
    this.rpcUnavailable = false,
    this.intentionallyEmpty = false,
    this.loadError = false,
    this.accessDenied = false,
  });

  final ReferenceBundle? bundle;
  final bool isDemoFallback;
  final bool rpcUnavailable;
  final bool intentionallyEmpty;
  final bool loadError;
  final bool accessDenied;

  bool get hideReference =>
      intentionallyEmpty && !isDemoFallback && !loadError && !accessDenied;

  bool get showLoadError =>
      loadError && (bundle == null || bundle!.articles.isEmpty);

  bool get showDemoBadge =>
      isDemoFallback || (bundle?.articles.any((a) => a.showDemoBadge) ?? false);

  ReferenceBundle get displayBundle {
    if (hideReference || showLoadError || accessDenied) {
      return const ReferenceBundle();
    }
    if (isDemoFallback || bundle == null || bundle!.articles.isEmpty) {
      return ReferenceBundle.demoLegacyHelp();
    }
    return bundle!;
  }

  List<ManagedReferenceArticle> get displayArticles => displayBundle.articles;
}

abstract class ReferenceRpcClient {
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});
}

class SupabaseReferenceRpcClient implements ReferenceRpcClient {
  SupabaseReferenceRpcClient([SupabaseClient? client]) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _resolvedClient => _client ?? Supabase.instance.client;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {
    return _resolvedClient.rpc(function, params: params);
  }
}

/// Cache-first reader for Info tab reference section.
class ReferenceService {
  ReferenceService({
    ReferenceRpcClient? rpcClient,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _rpc = rpcClient ?? SupabaseReferenceRpcClient(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId ??
            (() => Supabase.instance.client.auth.currentUser?.id);

  final ReferenceRpcClient _rpc;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function() _currentUserId;

  static const String keyPrefix = 'reference_bundle_v1';

  String _key() {
    final id = (_currentUserId() ?? '').trim();
    return id.isEmpty ? '${keyPrefix}__anon' : '${keyPrefix}__$id';
  }

  Future<ReferenceLoadResult> loadCached() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_key());
      if (raw == null || raw.isEmpty) {
        return const ReferenceLoadResult(isDemoFallback: true);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const ReferenceLoadResult(isDemoFallback: true);
      }
      final bundle = ReferenceBundle.tryParse(decoded);
      if (bundle == null || bundle.articles.isEmpty) {
        return const ReferenceLoadResult(isDemoFallback: true);
      }
      return ReferenceLoadResult(bundle: bundle);
    } catch (e) {
      debugPrint('[reference] cache read failed: $e');
      return const ReferenceLoadResult(isDemoFallback: true);
    }
  }

  Future<ReferenceLoadResult> load({bool writeCache = true}) async {
    try {
      final response = await _rpc.rpc('get_my_reference_bundle');
      final bundle = _parseBundle(response);
      if (bundle == null) {
        if (writeCache) await _clearCache();
        return const ReferenceLoadResult(intentionallyEmpty: true);
      }
      if (bundle.articles.isEmpty) {
        if (writeCache) await _clearCache();
        return const ReferenceLoadResult(intentionallyEmpty: true);
      }
      if (writeCache) await _writeCache(bundle);
      return ReferenceLoadResult(bundle: bundle);
    } on PostgrestException catch (error) {
      if (_isMissingRpc(error)) {
        return const ReferenceLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      if (_isAccessDenied(error)) {
        await _clearCache();
        return const ReferenceLoadResult(accessDenied: true);
      }
      rethrow;
    } catch (error) {
      if (_isMissingRpcMessage(error.toString())) {
        return const ReferenceLoadResult(
          isDemoFallback: true,
          rpcUnavailable: true,
        );
      }
      rethrow;
    }
  }

  Future<void> submitCorrection({
    required String contentItemId,
    required String note,
  }) async {
    await _rpc.rpc(
      'submit_content_correction',
      params: {
        'p_content_item_id': contentItemId,
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

  Future<void> _writeCache(ReferenceBundle bundle) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
        _key(),
        jsonEncode(_bundleToCacheJson(bundle)),
      );
    } catch (e) {
      debugPrint('[reference] cache write failed: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(_key());
    } catch (_) {}
  }

  ReferenceBundle? _parseBundle(dynamic response) {
    final map = _asMap(response);
    if (map == null) return null;
    return ReferenceBundle.tryParse(map);
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

  Map<String, dynamic> _bundleToCacheJson(ReferenceBundle bundle) {
    return {
      'categories': [
        for (final category in bundle.categories) category.toWireJson(),
      ],
      'articles': [
        for (final article in bundle.articles)
          {
            'id': article.id,
            'title': article.title,
            'template_key': 'reference_article_v1',
            'schema_version': article.schemaVersion,
            'origin': _originWire(article.origin),
            'sort_order': article.sortOrder,
            'category_id': article.categoryId,
            'category_title': article.categoryTitle,
            'payload': article.payload.toWireJson(
              schemaVersion: article.schemaVersion,
            ),
          },
      ],
    };
  }

  String _originWire(ContentOrigin origin) {
    switch (origin) {
      case ContentOrigin.demo:
        return 'demo';
      case ContentOrigin.admin:
        return 'admin';
      case ContentOrigin.importSource:
        return 'import';
      case ContentOrigin.userSubmission:
        return 'user_submission';
    }
  }

  bool _isMissingRpc(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == 'PGRST202' || code == '42883') return true;
    return _isMissingRpcMessage(error.message);
  }

  bool _isMissingRpcMessage(String raw) {
    final message = raw.toLowerCase();
    final namesFunction = message.contains('get_my_reference_bundle');
    final missingPhrase = message.contains('could not find the function') ||
        message.contains('does not exist') ||
        message.contains('undefined_function') ||
        message.contains('undefined function');
    return missingPhrase && namesFunction;
  }

  bool _isAccessDenied(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == '42501' || code == 'P0002' || code == '28000') return true;
    final message = error.message.toLowerCase();
    return message.contains('forbidden') ||
        message.contains('not_found') ||
        message.contains('not found') ||
        message.contains('jwt');
  }
}
