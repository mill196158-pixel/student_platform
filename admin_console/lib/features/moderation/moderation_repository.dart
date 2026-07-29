import 'dart:convert';



import 'package:student_ui/student_ui.dart';

import 'package:supabase_flutter/supabase_flutter.dart';



import 'moderation_queue_item.dart';



abstract class ModerationRpcClient {

  Future<dynamic> rpc(String function, {Map<String, dynamic>? params});

}



class SupabaseModerationRpcClient implements ModerationRpcClient {

  SupabaseModerationRpcClient([SupabaseClient? client])

      : _client = client ?? Supabase.instance.client;



  final SupabaseClient _client;



  @override

  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) {

    return _client.rpc(function, params: params);

  }

}



class SupabaseModerationRepository implements ModerationRepository {

  SupabaseModerationRepository({ModerationRpcClient? rpcClient})

      : _rpc = rpcClient ?? SupabaseModerationRpcClient();



  final ModerationRpcClient _rpc;



  Future<dynamic> _call(String function, [Map<String, dynamic>? params]) async {

    try {

      return await _rpc.rpc(function, params: params);

    } on PostgrestException catch (error) {

      throw _mapError(error);

    }

  }



  ModerationRepositoryException _mapError(PostgrestException error) {

    final code = error.code ?? '';

    final message = error.message.toLowerCase();

    if (code == '42501' || message.contains('forbidden')) {

      return const ModerationRepositoryException(

        'Недостаточно прав для модерации.',

        isForbidden: true,

      );

    }

    if (message.contains('could not find the function') || code == 'PGRST202') {

      return const ModerationRepositoryException(

        'Moderation RPC ещё не применены на remote (ожидается локальный apply).',

      );

    }

    return ModerationRepositoryException(error.message);

  }



  @override

  Future<List<LegacyReviewQueueItem>> listLegacyReviewQueue({

    String status = 'queue',

    int limit = 50,

  }) async {

    final data = await _call('admin_list_moderation_queue', {

      'p_status': status,

      'p_limit': limit,

    });

    return _parseLegacyList(data);

  }



  @override

  Future<List<UnifiedModerationQueueItem>> listUnifiedQueue({

    List<ModerationQueueDomain>? domains,

    String status = 'open',

    int limit = 50,

    int offset = 0,

    DateTime? since,

    String? authorUserId,

    String? assigneeUserId,

    int? minPriority,

  }) async {

    final data = await _call('admin_list_unified_moderation_queue', {

      if (domains != null && domains.isNotEmpty)

        'p_domains': domains.map((d) => d.wireValue).toList(),

      'p_status': status,

      'p_limit': limit,

      'p_offset': offset,

      if (since != null) 'p_since': since.toUtc().toIso8601String(),

      if (authorUserId != null && authorUserId.trim().isNotEmpty)

        'p_author_user_id': authorUserId.trim(),

      if (assigneeUserId != null && assigneeUserId.trim().isNotEmpty)

        'p_assignee_user_id': assigneeUserId.trim(),

      if (minPriority != null) 'p_min_priority': minPriority,

    });

    return _parseUnifiedList(data);

  }



  @override

  Future<List<ContentCorrectionQueueItem>> listContentCorrections({

    String status = 'open',

    int limit = 50,

    int offset = 0,

  }) async {

    final data = await _call('admin_list_content_corrections', {

      'p_status': status,

      'p_limit': limit,

      'p_offset': offset,

    });

    return _parseCorrectionList(data);

  }



  @override

  Future<List<ModerationHistoryEntry>> listReviewHistory({

    required String reviewId,

    int limit = 50,

  }) async {

    final data = await _call('admin_list_review_moderation_actions', {

      'p_review_id': reviewId,

      'p_limit': limit,

    });

    return _parseHistoryList(data);

  }



  @override

  Future<List<ModerationHistoryEntry>> listVacancyHistory({

    required String vacancyId,

    int limit = 50,

  }) async {

    final data = await _call('admin_list_vacancy_moderation_actions', {

      'p_vacancy_id': vacancyId,

      'p_limit': limit,

    });

    return _parseHistoryList(data);

  }



  @override

  Future<void> moderateLegacyReview({

    required String reviewId,

    required String action,

    required String reason,

  }) async {

    await _call('admin_moderate_review', {

      'p_review_id': reviewId,

      'p_action': action,

      'p_reason_text': reason,

    });

  }



  @override

  Future<void> applyUnifiedAction({

    required ModerationQueueDomain domain,

    required String entityId,

    required String action,

    required String reason,

    int? expectedRowVersion,

  }) async {

    await _call('admin_moderation_action', {

      'p_domain': domain.wireValue,

      'p_entity_id': entityId,

      'p_action': action,

      'p_reason': reason,

      if (expectedRowVersion != null)

        'p_expected_row_version': expectedRowVersion,

    });

  }



  List<LegacyReviewQueueItem> _parseLegacyList(dynamic data) {

    final rows = _asList(data);

    return rows.map(LegacyReviewQueueItem.fromJson).toList();

  }



  List<UnifiedModerationQueueItem> _parseUnifiedList(dynamic data) {

    final rows = _asList(data);

    final items = <UnifiedModerationQueueItem>[];

    for (final row in rows) {

      final item = UnifiedModerationQueueItem.tryParse(row);

      if (item != null) items.add(item);

    }

    return items;

  }



  List<ContentCorrectionQueueItem> _parseCorrectionList(dynamic data) {

    final rows = _asList(data);

    return rows.map(ContentCorrectionQueueItem.fromJson).toList();

  }



  List<ModerationHistoryEntry> _parseHistoryList(dynamic data) {

    final rows = _asList(data);

    return rows.map(ModerationHistoryEntry.fromJson).toList();

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



/// In-memory moderation data for local prototype / widget tests.

class LocalModerationRepository implements ModerationRepository {

  LocalModerationRepository() {

    _legacy = [

      LegacyReviewQueueItem(

        reviewId: 'local-review-1',

        entityType: ReviewEntityType.teacher,

        entityId: 'teacher-1',

        status: 'active',

        tagScores: const {'clarity': 4},

        openReports: 2,

      ),

    ];

    _unified = [

      UnifiedModerationQueueItem(

        domain: ModerationQueueDomain.review,

        entityId: 'local-review-1',

        parentId: 'teacher-1',

        title: ReviewEntityType.teacher.wireValue,

        detail: 'Отзыв ожидает проверки',

        status: ReviewModerationStatus.pending.wireValue,

        openReports: 2,

        updatedAt: DateTime.utc(2026, 7, 29, 9),

        authorUserId: 'author-1',

        authorLabel: 'Студент А.',

        priority: 2,

      ),

      UnifiedModerationQueueItem(

        domain: ModerationQueueDomain.reviewReport,

        entityId: 'local-review-report-1',

        parentId: 'local-review-1',

        title: 'review_report',

        detail: 'Жалоба: spam',

        status: 'open',

        reasonCode: 'spam',

        updatedAt: DateTime.utc(2026, 7, 29, 8, 30),

        authorUserId: 'reporter-1',

        authorLabel: 'Студент Б.',

        priority: 10,

      ),

      UnifiedModerationQueueItem(

        domain: ModerationQueueDomain.vacancy,

        entityId: 'local-vacancy-1',

        title: 'Стажировка в IT',

        detail: 'Пользовательская заявка',

        status: 'submitted',

        rowVersion: 3,

        updatedAt: DateTime.utc(2026, 7, 29, 8),

        authorUserId: 'author-2',

        authorLabel: 'Студент В.',

        priority: 5,

      ),

      UnifiedModerationQueueItem(

        domain: ModerationQueueDomain.vacancyReport,

        entityId: 'local-vacancy-report-1',

        parentId: 'local-vacancy-1',

        title: 'vacancy_report',

        detail: 'Жалоба: abuse',

        status: 'open',

        reasonCode: 'abuse',

        updatedAt: DateTime.utc(2026, 7, 29, 7, 30),

        authorUserId: 'reporter-2',

        authorLabel: 'Студент Г.',

        priority: 30,

      ),

      UnifiedModerationQueueItem(

        domain: ModerationQueueDomain.contentCorrection,

        entityId: 'local-correction-1',

        parentId: 'content-item-1',

        title: 'Справочник: расписание',

        detail: 'Неверная ссылка на PDF',

        status: 'open',

        updatedAt: DateTime.utc(2026, 7, 29, 7),

        authorUserId: 'reporter-3',

        authorLabel: 'Студент Д.',

      ),

    ];

    _corrections = [

      ContentCorrectionQueueItem(

        id: 'local-correction-1',

        contentItemId: 'content-item-1',

        contentTitle: 'Справочник: расписание',

        status: 'open',

        note: 'Неверная ссылка на PDF',

        templateKey: 'reference_article',

      ),

    ];

    _reviewHistory = {

      'local-review-1': [

        ModerationHistoryEntry(

          action: 'approve',

          reasonText: 'Соответствует правилам',

          createdAt: DateTime.utc(2026, 7, 28),

        ),

      ],

    };

    _vacancyHistory = {

      'local-vacancy-1': [

        ModerationHistoryEntry(

          action: 'submit',

          fromStatus: 'draft',

          toStatus: 'submitted',

          createdAt: DateTime.utc(2026, 7, 27),

        ),

      ],

    };

  }



  late List<LegacyReviewQueueItem> _legacy;

  late List<UnifiedModerationQueueItem> _unified;

  late List<ContentCorrectionQueueItem> _corrections;

  late Map<String, List<ModerationHistoryEntry>> _reviewHistory;

  late Map<String, List<ModerationHistoryEntry>> _vacancyHistory;



  @override

  Future<List<LegacyReviewQueueItem>> listLegacyReviewQueue({

    String status = 'queue',

    int limit = 50,

  }) async {

    return _legacy.take(limit).toList();

  }



  @override

  Future<List<UnifiedModerationQueueItem>> listUnifiedQueue({

    List<ModerationQueueDomain>? domains,

    String status = 'open',

    int limit = 50,

    int offset = 0,

    DateTime? since,

    String? authorUserId,

    String? assigneeUserId,

    int? minPriority,

  }) async {

    var filtered = _unified;

    if (domains != null && domains.isNotEmpty) {

      filtered = filtered.where((e) => domains.contains(e.domain)).toList();

    }

    if (status != 'all') {

      filtered = filtered.where((e) {

        final isOpen = e.status == 'open' ||

            e.status == ReviewModerationStatus.pending.wireValue ||

            e.status == 'submitted' ||

            e.status == 'in_moderation';

        return status == 'open' ? isOpen : !isOpen;

      }).toList();

    }

    if (since != null) {

      filtered = filtered

          .where(

            (e) => e.updatedAt == null || !e.updatedAt!.isBefore(since),

          )

          .toList();

    }

    if (authorUserId != null && authorUserId.trim().isNotEmpty) {

      filtered = filtered

          .where((e) => e.authorUserId == authorUserId.trim())

          .toList();

    }

    if (assigneeUserId != null && assigneeUserId.trim().isNotEmpty) {

      filtered = filtered

          .where((e) => e.assigneeUserId == assigneeUserId.trim())

          .toList();

    }

    if (minPriority != null) {

      filtered = filtered

          .where((e) => (e.priority ?? 0) >= minPriority)

          .toList();

    }

    final start = offset.clamp(0, filtered.length);

    final end = (start + limit).clamp(0, filtered.length);

    return filtered.sublist(start, end);

  }



  @override

  Future<List<ContentCorrectionQueueItem>> listContentCorrections({

    String status = 'open',

    int limit = 50,

    int offset = 0,

  }) async {

    var filtered = _corrections;

    if (status != 'all') {

      filtered = filtered.where((e) => e.status == status).toList();

    }

    final start = offset.clamp(0, filtered.length);

    final end = (start + limit).clamp(0, filtered.length);

    return filtered.sublist(start, end);

  }



  @override

  Future<List<ModerationHistoryEntry>> listReviewHistory({

    required String reviewId,

    int limit = 50,

  }) async {

    return (_reviewHistory[reviewId] ?? const []).take(limit).toList();

  }



  @override

  Future<List<ModerationHistoryEntry>> listVacancyHistory({

    required String vacancyId,

    int limit = 50,

  }) async {

    return (_vacancyHistory[vacancyId] ?? const []).take(limit).toList();

  }



  @override

  Future<void> moderateLegacyReview({

    required String reviewId,

    required String action,

    required String reason,

  }) async {

    final idx = _legacy.indexWhere((e) => e.reviewId == reviewId);

    if (idx < 0) {

      throw const ModerationRepositoryException('Отзыв не найден.');

    }

    final current = _legacy[idx];

    _legacy = [..._legacy]

      ..[idx] = LegacyReviewQueueItem(

        reviewId: current.reviewId,

        entityType: current.entityType,

        entityId: current.entityId,

        status: action == 'hide' ? 'hidden' : 'active',

        bodyText: current.bodyText,

        tagScores: current.tagScores,

        openReports: action == 'hide' ? 0 : current.openReports,

        hiddenReason: reason,

      );

    _appendReviewHistory(reviewId, action, reason);

  }



  @override

  Future<void> applyUnifiedAction({

    required ModerationQueueDomain domain,

    required String entityId,

    required String action,

    required String reason,

    int? expectedRowVersion,

  }) async {

    final idx = _unified.indexWhere(

      (e) => e.domain == domain && e.entityId == entityId,

    );

    if (idx < 0) {

      throw const ModerationRepositoryException('Элемент очереди не найден.');

    }

    final current = _unified[idx];

    final nextStatus = switch (domain) {

      ModerationQueueDomain.review => switch (action) {

          'approve' || 'restore' => ReviewModerationStatus.approved.wireValue,

          'reject' ||

          'remove_violation' ||

          'request_clarification' =>

            ReviewModerationStatus.rejected.wireValue,

          _ => current.status,

        },

      ModerationQueueDomain.reviewReport ||

      ModerationQueueDomain.vacancyReport =>

        action == 'resolve' ? 'resolved' : 'rejected',

      ModerationQueueDomain.vacancy => switch (action) {

          'take_in_moderation' => 'in_moderation',

          'approve' => 'approved',

          'reject' => 'rejected',

          'request_clarification' => 'draft',

          _ => current.status,

        },

      ModerationQueueDomain.contentCorrection =>

        action == 'resolve' ? 'resolved' : 'rejected',

    };

    _unified = [..._unified]

      ..[idx] = UnifiedModerationQueueItem(

        domain: current.domain,

        entityId: current.entityId,

        parentId: current.parentId,

        title: current.title,

        detail: reason.isEmpty ? current.detail : reason,

        status: nextStatus,

        reasonCode: current.reasonCode,

        openReports: current.openReports,

        rowVersion: domain == ModerationQueueDomain.vacancy

            ? (current.rowVersion ?? 0) + 1

            : current.rowVersion,

        createdAt: current.createdAt,

        updatedAt: DateTime.now().toUtc(),

        authorUserId: current.authorUserId,

        authorLabel: current.authorLabel,

        assigneeUserId: current.assigneeUserId,

        priority: current.priority,

      );



    if (domain == ModerationQueueDomain.review) {

      _appendReviewHistory(entityId, action, reason);

    } else if (domain == ModerationQueueDomain.vacancy) {

      _appendVacancyHistory(entityId, action, current.status, nextStatus, reason);

    }

  }



  void _appendReviewHistory(String reviewId, String action, String reason) {

    final entry = ModerationHistoryEntry(

      action: action,

      reasonText: reason,

      createdAt: DateTime.now().toUtc(),

    );

    _reviewHistory = {

      ..._reviewHistory,

      reviewId: [entry, ...(_reviewHistory[reviewId] ?? const [])],

    };

  }



  void _appendVacancyHistory(

    String vacancyId,

    String action,

    String fromStatus,

    String toStatus,

    String reason,

  ) {

    final entry = ModerationHistoryEntry(

      action: action,

      reasonText: reason,

      fromStatus: fromStatus,

      toStatus: toStatus,

      createdAt: DateTime.now().toUtc(),

    );

    _vacancyHistory = {

      ..._vacancyHistory,

      vacancyId: [entry, ...(_vacancyHistory[vacancyId] ?? const [])],

    };

  }

}

