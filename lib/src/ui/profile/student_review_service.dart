import 'dart:convert';



import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_ui/student_ui.dart';

import 'package:supabase_flutter/supabase_flutter.dart';



class EntityReviewSummaryResult {

  const EntityReviewSummaryResult({

    this.summary,

    this.isDemoFallback = false,

    this.rpcUnavailable = false,

    this.intentionallyEmpty = false,

    this.loadError = false,

  });



  final EntityReviewSummary? summary;

  final bool isDemoFallback;

  final bool rpcUnavailable;

  final bool intentionallyEmpty;

  final bool loadError;



  bool get hideSummary =>

      intentionallyEmpty && !isDemoFallback && !loadError;



  EntityReviewSummary get displaySummary => summary ??

      EntityReviewSummary(

        entityType: ReviewEntityType.subject,

        entityId: 'demo-subject',

        activeCount: 2,

        tagAverages: const {'usefulness': 3.5, 'workload': 4.2},

        structuredEnabled: true,

      );

}



class StudentReviewSubmitResult {

  const StudentReviewSubmitResult({

    this.reviewId,

    this.moderationStatus,

    this.isDemoFallback = false,

    this.rpcUnavailable = false,

    this.errorMessage,

  });



  final String? reviewId;

  final ReviewModerationStatus? moderationStatus;

  final bool isDemoFallback;

  final bool rpcUnavailable;

  final String? errorMessage;



  bool get ok => reviewId != null || isDemoFallback;



  bool get isPendingModeration =>

      moderationStatus == ReviewModerationStatus.pending;

}



class MyEntityReviewsResult {

  const MyEntityReviewsResult({

    this.items = const [],

    this.isDemoFallback = false,

    this.rpcUnavailable = false,

  });



  final List<MyEntityReviewItem> items;

  final bool isDemoFallback;

  final bool rpcUnavailable;

}



abstract class StudentReviewRpcClient {

  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});

}



class SupabaseStudentReviewRpcClient implements StudentReviewRpcClient {

  SupabaseStudentReviewRpcClient([SupabaseClient? client])

      : _client = client ?? Supabase.instance.client;



  final SupabaseClient _client;



  @override

  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {

    return _client.rpc(function, params: params);

  }

}



/// Thin mobile wrapper for Stage 13.6 / Stage 18 entity reviews.

///

/// Read: `get_entity_review_summary`, `get_my_entity_reviews`.

/// Submit: `submit_my_entity_review` first; fall back to legacy

/// `upsert_my_entity_review` only when Stage 18 RPC is missing.

/// Missing RPC → labeled demo fallback. No second review system.

class StudentReviewService {

  StudentReviewService({

    StudentReviewRpcClient? rpcClient,

    Future<SharedPreferences> Function()? prefs,

    String? Function()? currentUserId,

  })  : _rpc = rpcClient ?? SupabaseStudentReviewRpcClient(),

        _prefs = prefs ?? SharedPreferences.getInstance,

        _currentUserId = currentUserId ??

            (() => Supabase.instance.client.auth.currentUser?.id);



  final StudentReviewRpcClient _rpc;

  final Future<SharedPreferences> Function() _prefs;

  final String? Function() _currentUserId;



  static const String myReviewKeyPrefix = 'my_entity_review_v1';



  String _myReviewKey(ReviewEntityType type, String entityId) {

    final userId = (_currentUserId() ?? '').trim();

    final scope = userId.isEmpty ? 'anon' : userId;

    return '${myReviewKeyPrefix}__${scope}__${type.wireValue}__$entityId';

  }



  Future<EntityReviewSummaryResult> loadSummary({

    required ReviewEntityType entityType,

    required String entityId,

  }) async {

    final id = entityId.trim();

    if (id.isEmpty) {

      return const EntityReviewSummaryResult(loadError: true);

    }



    try {

      final response = await _rpc.rpc(

        'get_entity_review_summary',

        params: {

          'p_entity_type': entityType.wireValue,

          'p_entity_id': id,

        },

      );

      final map = _asMap(response);

      final summary = EntityReviewSummary.tryParse(map);

      if (summary == null) {

        return const EntityReviewSummaryResult(loadError: true);

      }

      if (!summary.hasReviews) {

        return EntityReviewSummaryResult(

          summary: summary,

          intentionallyEmpty: true,

        );

      }

      return EntityReviewSummaryResult(summary: summary);

    } on PostgrestException catch (error) {

      if (_isMissingRpc(error, 'get_entity_review_summary')) {

        debugPrint(

          '[reviews] get_entity_review_summary unavailable: ${error.message}',

        );

        return const EntityReviewSummaryResult(

          isDemoFallback: true,

          rpcUnavailable: true,

        );

      }

      rethrow;

    } catch (error) {

      if (_isMissingRpcMessage(error.toString(), 'get_entity_review_summary')) {

        return const EntityReviewSummaryResult(

          isDemoFallback: true,

          rpcUnavailable: true,

        );

      }

      debugPrint('[reviews] summary load failed: $error');

      return const EntityReviewSummaryResult(loadError: true);

    }

  }



  Future<MyEntityReviewsResult> loadMyReviews({int limit = 50}) async {

    final userId = (_currentUserId() ?? '').trim();

    if (userId.isEmpty) {

      return const MyEntityReviewsResult(rpcUnavailable: true);

    }



    try {

      final response = await _rpc.rpc(

        'get_my_entity_reviews',

        params: {'p_limit': limit},

      );

      final items = _parseMyReviewsList(response);

      if (items.isEmpty) {

        await _clearScopedMyReviewsCache();

        return const MyEntityReviewsResult(items: []);

      }

      return MyEntityReviewsResult(items: items);

    } on PostgrestException catch (error) {

      if (_isMissingRpc(error, 'get_my_entity_reviews')) {

        final cached = await _loadAllCachedMyReviews();

        return MyEntityReviewsResult(

          items: cached,

          isDemoFallback: cached.isEmpty,

          rpcUnavailable: true,

        );

      }

      rethrow;

    } catch (error) {

      if (_isMissingRpcMessage(error.toString(), 'get_my_entity_reviews')) {

        final cached = await _loadAllCachedMyReviews();

        return MyEntityReviewsResult(

          items: cached,

          isDemoFallback: cached.isEmpty,

          rpcUnavailable: true,

        );

      }

      debugPrint('[reviews] my-reviews load failed: $error');

      final cached = await _loadAllCachedMyReviews();

      return MyEntityReviewsResult(items: cached);

    }

  }



  Future<StudentReviewCardPayload?> loadCachedMyReview({

    required ReviewEntityType entityType,

    required String entityId,

    required String entityLabel,

  }) async {

    try {

      final prefs = await _prefs();

      final raw = prefs.getString(_myReviewKey(entityType, entityId));

      if (raw == null || raw.isEmpty) return null;

      final map = jsonDecode(raw);

      if (map is! Map) return null;

      final payload = _payloadFromCache(

        Map<String, dynamic>.from(map),

        entityType: entityType,

        entityLabel: entityLabel,

      );

      return payload;

    } catch (e) {

      debugPrint('[reviews] my-review cache read failed: $e');

      return null;

    }

  }



  Future<StudentReviewSubmitResult> submit({

    required ReviewEntityType entityType,

    required String entityId,

    required String entityLabel,

    Map<String, int> tagScores = const {},

    String? bodyText,

  }) async {

    final userId = (_currentUserId() ?? '').trim();

    if (userId.isEmpty) {

      return const StudentReviewSubmitResult(

        isDemoFallback: true,

        rpcUnavailable: true,

      );

    }



    final id = entityId.trim();

    if (id.isEmpty) {

      return const StudentReviewSubmitResult(errorMessage: 'invalid_entity');

    }



    final trimmedBody = bodyText?.trim();



    final stage18 = await _submitViaStage18(

      entityType: entityType,

      entityId: id,

      entityLabel: entityLabel,

      tagScores: tagScores,

      bodyText: trimmedBody,

      missingOnly: true,

    );

    if (stage18 != null) return stage18;



    return _submitViaLegacyUpsert(

      entityType: entityType,

      entityId: id,

      entityLabel: entityLabel,

      tagScores: tagScores,

      bodyText: trimmedBody,

    );

  }



  Future<StudentReviewSubmitResult?> _submitViaStage18({

    required ReviewEntityType entityType,

    required String entityId,

    required String entityLabel,

    required Map<String, int> tagScores,

    String? bodyText,

    bool missingOnly = false,

  }) async {

    final scoresJson = {

      for (final entry in tagScores.entries) entry.key: entry.value,

    };

    try {

      final response = await _rpc.rpc(

        'submit_my_entity_review',

        params: {

          'p_entity_type': entityType.wireValue,

          'p_entity_id': entityId,

          'p_tag_scores': scoresJson,

          'p_body_text': bodyText?.isEmpty == true ? null : bodyText,

        },

      );

      final map = _asMap(response);

      if (map == null) {

        return const StudentReviewSubmitResult(errorMessage: 'invalid_response');

      }

      final reviewId = map['review_id']?.toString().trim();

      final moderation = ReviewModerationStatus.tryParse(

        map['moderation_status'],

      );

      if (reviewId == null || reviewId.isEmpty) {

        return const StudentReviewSubmitResult(errorMessage: 'empty_review_id');

      }

      await _cacheMyReview(

        entityType: entityType,

        entityId: entityId,

        entityLabel: entityLabel,

        tagScores: tagScores,

        bodyText: bodyText,

        reviewId: reviewId,

        moderationStatus: moderation,

      );

      return StudentReviewSubmitResult(

        reviewId: reviewId,

        moderationStatus: moderation,

      );

    } on PostgrestException catch (error) {

      if (_isMissingRpc(error, 'submit_my_entity_review')) {

        if (missingOnly) return null;

        debugPrint(

          '[reviews] submit_my_entity_review unavailable: ${error.message}',

        );

        return _demoFallbackSubmit(

          entityType: entityType,

          entityId: entityId,

          entityLabel: entityLabel,

          tagScores: tagScores,

          bodyText: bodyText,

        );

      }

      return StudentReviewSubmitResult(errorMessage: error.message);

    } catch (error) {

      if (_isMissingRpcMessage(error.toString(), 'submit_my_entity_review')) {

        if (missingOnly) return null;

        return _demoFallbackSubmit(

          entityType: entityType,

          entityId: entityId,

          entityLabel: entityLabel,

          tagScores: tagScores,

          bodyText: bodyText,

        );

      }

      debugPrint('[reviews] Stage 18 submit failed: $error');

      return StudentReviewSubmitResult(errorMessage: error.toString());

    }

  }



  Future<StudentReviewSubmitResult> _submitViaLegacyUpsert({

    required ReviewEntityType entityType,

    required String entityId,

    required String entityLabel,

    required Map<String, int> tagScores,

    String? bodyText,

  }) async {

    final scoresJson = {

      for (final entry in tagScores.entries) entry.key: entry.value,

    };

    try {

      final reviewId = await _rpc.rpc(

        'upsert_my_entity_review',

        params: {

          'p_entity_type': entityType.wireValue,

          'p_entity_id': entityId,

          'p_tag_scores': scoresJson,

          'p_body_text': bodyText?.isEmpty == true ? null : bodyText,

        },

      );

      final parsedId = reviewId?.toString().trim();

      if (parsedId == null || parsedId.isEmpty) {

        return const StudentReviewSubmitResult(errorMessage: 'empty_review_id');

      }

      await _cacheMyReview(

        entityType: entityType,

        entityId: entityId,

        entityLabel: entityLabel,

        tagScores: tagScores,

        bodyText: bodyText,

        reviewId: parsedId,

        moderationStatus: ReviewModerationStatus.approved,

      );

      return StudentReviewSubmitResult(

        reviewId: parsedId,

        moderationStatus: ReviewModerationStatus.approved,

      );

    } on PostgrestException catch (error) {

      if (_isMissingRpc(error, 'upsert_my_entity_review')) {

        return _demoFallbackSubmit(

          entityType: entityType,

          entityId: entityId,

          entityLabel: entityLabel,

          tagScores: tagScores,

          bodyText: bodyText,

        );

      }

      return StudentReviewSubmitResult(errorMessage: error.message);

    } catch (error) {

      if (_isMissingRpcMessage(error.toString(), 'upsert_my_entity_review')) {

        return _demoFallbackSubmit(

          entityType: entityType,

          entityId: entityId,

          entityLabel: entityLabel,

          tagScores: tagScores,

          bodyText: bodyText,

        );

      }

      debugPrint('[reviews] legacy upsert failed: $error');

      return StudentReviewSubmitResult(errorMessage: error.toString());

    }

  }



  Future<StudentReviewSubmitResult> _demoFallbackSubmit({

    required ReviewEntityType entityType,

    required String entityId,

    required String entityLabel,

    required Map<String, int> tagScores,

    String? bodyText,

  }) async {

    await _cacheMyReview(

      entityType: entityType,

      entityId: entityId,

      entityLabel: entityLabel,

      tagScores: tagScores,

      bodyText: bodyText,

      reviewId: 'demo-review',

      moderationStatus: ReviewModerationStatus.pending,

    );

    return const StudentReviewSubmitResult(

      reviewId: 'demo-review',

      moderationStatus: ReviewModerationStatus.pending,

      isDemoFallback: true,

      rpcUnavailable: true,

    );

  }



  Future<void> clearAll() async {

    await _clearScopedMyReviewsCache();

  }



  Future<void> _clearScopedMyReviewsCache() async {

    try {

      final prefs = await _prefs();

      final userId = (_currentUserId() ?? '').trim();

      final scope = userId.isEmpty ? 'anon' : userId;

      final prefix = '${myReviewKeyPrefix}__${scope}__';

      for (final key in prefs.getKeys()) {

        if (key.startsWith(prefix)) {

          await prefs.remove(key);

        }

      }

    } catch (e) {

      debugPrint('[reviews] scoped cache clear failed: $e');

    }

  }



  Future<List<MyEntityReviewItem>> _loadAllCachedMyReviews() async {

    final userId = (_currentUserId() ?? '').trim();

    final scope = userId.isEmpty ? 'anon' : userId;

    final prefix = '${myReviewKeyPrefix}__${scope}__';

    final items = <MyEntityReviewItem>[];

    try {

      final prefs = await _prefs();

      for (final key in prefs.getKeys()) {

        if (!key.startsWith(prefix)) continue;

        final raw = prefs.getString(key);

        if (raw == null || raw.isEmpty) continue;

        final map = jsonDecode(raw);

        if (map is! Map) continue;

        final json = Map<String, dynamic>.from(map);

        final parts = key.substring(prefix.length).split('__');

        if (parts.length != 2) continue;

        final entityType = ReviewEntityType.tryParse(parts[0]);

        final entityId = parts[1].trim();

        if (entityType == null || entityId.isEmpty) continue;

        final reviewId = json['review_id']?.toString().trim();

        if (reviewId == null || reviewId.isEmpty) continue;

        final tagScores = <String, int>{};

        final rawScores = json['tag_scores'];

        if (rawScores is Map) {

          for (final entry in rawScores.entries) {

            final value = entry.value;

            if (value is num) tagScores['${entry.key}'] = value.toInt();

          }

        }

        items.add(

          MyEntityReviewItem(

            reviewId: reviewId,

            entityType: entityType,

            entityId: entityId,

            entityLabel: json['entity_label']?.toString().trim().isNotEmpty ==

                    true

                ? json['entity_label'].toString()

                : entityId,

            tagScores: tagScores,

            bodyPreview: json['body_text']?.toString(),

            moderationStatus: ReviewModerationStatus.tryParse(

              json['moderation_status'],

            ),

            moderationReason: () {

              final raw = json['moderation_reason'] ?? json['moderationReason'];

              final text = raw?.toString().trim();

              return (text == null || text.isEmpty) ? null : text;

            }(),

          ),

        );

      }

    } catch (e) {

      debugPrint('[reviews] cached my-reviews scan failed: $e');

    }

    return items;

  }



  List<MyEntityReviewItem> _parseMyReviewsList(dynamic data) {

    dynamic value = data;

    if (value is String && value.isNotEmpty) {

      try {

        value = jsonDecode(value);

      } catch (_) {

        return const [];

      }

    }

    if (value is! List) return const [];

    final items = <MyEntityReviewItem>[];

    for (final row in value) {

      if (row is! Map) continue;

      final item = MyEntityReviewItem.tryParse(Map<String, dynamic>.from(row));

      if (item != null) items.add(item);

    }

    return items;

  }



  Future<void> _cacheMyReview({

    required ReviewEntityType entityType,

    required String entityId,

    required String entityLabel,

    required Map<String, int> tagScores,

    String? bodyText,

    required String reviewId,

    ReviewModerationStatus? moderationStatus,

  }) async {

    try {

      final prefs = await _prefs();

      await prefs.setString(

        _myReviewKey(entityType, entityId),

        jsonEncode({

          'review_id': reviewId,

          'entity_label': entityLabel,

          'tag_scores': tagScores,

          'body_text': bodyText,

          'moderation_status': moderationStatus?.wireValue,

        }),

      );

    } catch (e) {

      debugPrint('[reviews] my-review cache write failed: $e');

    }

  }



  StudentReviewCardPayload? _payloadFromCache(

    Map<String, dynamic> json, {

    required ReviewEntityType entityType,

    required String entityLabel,

  }) {

    final tagScores = <String, int>{};

    final rawScores = json['tag_scores'];

    if (rawScores is Map) {

      for (final entry in rawScores.entries) {

        final value = entry.value;

        if (value is num) tagScores['${entry.key}'] = value.toInt();

      }

    }

    return StudentReviewCardPayload(

      entityType: entityType,

      entityLabel: json['entity_label']?.toString().trim().isNotEmpty == true

          ? json['entity_label'].toString()

          : entityLabel,

      tagScores: tagScores,

      bodyPreview: json['body_text']?.toString(),

      moderationStatus: ReviewModerationStatus.tryParse(

        json['moderation_status'],

      ),

    );

  }



  bool _isMissingRpc(PostgrestException error, String functionName) {

    final code = (error.code ?? '').toUpperCase();

    if (code == 'PGRST202' || code == '42883') return true;

    return _isMissingRpcMessage(error.message, functionName);

  }



  bool _isMissingRpcMessage(String raw, String functionName) {

    final message = raw.toLowerCase();

    final namesFunction = message.contains(functionName.toLowerCase());

    final missingPhrase = message.contains('could not find the function') ||

        message.contains('does not exist') ||

        message.contains('undefined_function') ||

        message.contains('undefined function');

    return missingPhrase && namesFunction;

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

    if (value is Map) {

      return Map<String, dynamic>.from(value);

    }

    return null;

  }

}

