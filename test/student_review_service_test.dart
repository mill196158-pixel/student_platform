import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:student_platform/src/ui/profile/student_review_service.dart';

import 'package:student_ui/student_ui.dart';

import 'package:supabase_flutter/supabase_flutter.dart';



class _FakeReviewRpc implements StudentReviewRpcClient {

  _FakeReviewRpc({

    this.responses = const {},

    this.errors = const {},

  });



  final Map<String, dynamic> responses;

  final Map<String, Object> errors;

  final calls = <String>[];



  @override

  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {

    calls.add(function);

    if (errors.containsKey(function)) throw errors[function]!;

    if (responses.containsKey(function)) return responses[function];

    return null;

  }

}



void main() {

  TestWidgetsFlutterBinding.ensureInitialized();



  setUp(() {

    SharedPreferences.setMockInitialValues({});

  });



  test('loads get_entity_review_summary', () async {

    final rpc = _FakeReviewRpc(

      responses: {

        'get_entity_review_summary': {

          'entity_type': 'subject',

          'entity_id': 'sub-1',

          'active_count': 2,

          'tag_averages': {'workload': 3.5},

        },

      },

    );

    final service = StudentReviewService(

      rpcClient: rpc,

      currentUserId: () => 'user-a',

    );

    final result = await service.loadSummary(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-1',

    );

    expect(result.rpcUnavailable, isFalse);

    expect(result.summary?.activeCount, 2);

    expect(rpc.calls, ['get_entity_review_summary']);

  });



  test('summary empty hides like VacancyService', () async {

    final rpc = _FakeReviewRpc(

      responses: {

        'get_entity_review_summary': {

          'entity_type': 'teacher',

          'entity_id': 't-1',

          'active_count': 0,

          'tag_averages': {},

        },

      },

    );

    final service = StudentReviewService(rpcClient: rpc);

    final result = await service.loadSummary(

      entityType: ReviewEntityType.teacher,

      entityId: 't-1',

    );

    expect(result.intentionallyEmpty, isTrue);

    expect(result.hideSummary, isTrue);

  });



  test('missing summary RPC dual-reads to demo', () async {

    final rpc = _FakeReviewRpc(

      errors: {

        'get_entity_review_summary': const PostgrestException(

          message: 'Could not find the function public.get_entity_review_summary',

          code: 'PGRST202',

        ),

      },

    );

    final service = StudentReviewService(rpcClient: rpc);

    final result = await service.loadSummary(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-1',

    );

    expect(result.rpcUnavailable, isTrue);

    expect(result.isDemoFallback, isTrue);

    expect(result.displaySummary.activeCount, greaterThan(0));

  });



  test('submit uses submit_my_entity_review first', () async {

    final rpc = _FakeReviewRpc(

      responses: {

        'submit_my_entity_review': {

          'ok': true,

          'review_id': 'review-uuid-1',

          'moderation_status': 'pending',

        },

      },

    );

    final service = StudentReviewService(

      rpcClient: rpc,

      currentUserId: () => 'user-a',

    );

    final result = await service.submit(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-1',

      entityLabel: 'Math',

      tagScores: const {'usefulness': 4},

    );

    expect(result.ok, isTrue);

    expect(result.reviewId, 'review-uuid-1');

    expect(result.moderationStatus, ReviewModerationStatus.pending);

    expect(rpc.calls, ['submit_my_entity_review']);



    final cached = await service.loadCachedMyReview(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-1',

      entityLabel: 'Math',

    );

    expect(cached?.tagScores['usefulness'], 4);

    expect(cached?.moderationStatus, ReviewModerationStatus.pending);

  });



  test('falls back to upsert_my_entity_review when Stage 18 missing', () async {

    final rpc = _FakeReviewRpc(

      errors: {

        'submit_my_entity_review': const PostgrestException(

          message: 'Could not find the function public.submit_my_entity_review',

          code: 'PGRST202',

        ),

      },

      responses: {

        'upsert_my_entity_review': 'review-uuid-2',

      },

    );

    final service = StudentReviewService(

      rpcClient: rpc,

      currentUserId: () => 'user-a',

    );

    final result = await service.submit(

      entityType: ReviewEntityType.teacher,

      entityId: 't-1',

      entityLabel: 'Teacher',

      tagScores: const {'clarity': 5},

    );

    expect(result.reviewId, 'review-uuid-2');

    expect(result.moderationStatus, ReviewModerationStatus.approved);

    expect(rpc.calls, [

      'submit_my_entity_review',

      'upsert_my_entity_review',

    ]);

  });



  test('loadMyReviews parses get_my_entity_reviews', () async {

    final rpc = _FakeReviewRpc(

      responses: {

        'get_my_entity_reviews': [

          {

            'review_id': 'r-1',

            'entity_type': 'subject',

            'entity_id': 'sub-1',

            'entity_label': 'Math',

            'tag_scores': {'usefulness': 4},

            'moderation_status': 'rejected',

            'moderation_reason': 'Уточните нагрузку',

          },

        ],

      },

    );

    final service = StudentReviewService(

      rpcClient: rpc,

      currentUserId: () => 'user-a',

    );

    final result = await service.loadMyReviews();

    expect(result.items, hasLength(1));

    expect(result.items.first.entityLabel, 'Math');

    expect(result.items.first.moderationStatus, ReviewModerationStatus.rejected);

    expect(result.items.first.moderationReason, 'Уточните нагрузку');

  });



  test('loadMyReviews empty RPC clears scoped cache', () async {

    SharedPreferences.setMockInitialValues({

      'my_entity_review_v1__user-a__subject__sub-stale': jsonEncode({

        'review_id': 'stale-review',

        'entity_label': 'Stale',

        'tag_scores': {'usefulness': 2},

        'moderation_status': 'pending',

      }),

    });

    final rpc = _FakeReviewRpc(

      responses: {

        'get_my_entity_reviews': [],

      },

    );

    final service = StudentReviewService(

      rpcClient: rpc,

      currentUserId: () => 'user-a',

    );

    final result = await service.loadMyReviews();

    expect(result.items, isEmpty);

    expect(result.rpcUnavailable, isFalse);



    final cached = await service.loadCachedMyReview(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-stale',

      entityLabel: 'Stale',

    );

    expect(cached, isNull);

  });



  test('clearAll removes cached my reviews', () async {

    final rpc = _FakeReviewRpc(

      responses: {

        'submit_my_entity_review': {

          'review_id': 'review-uuid-3',

          'moderation_status': 'pending',

        },

      },

    );

    final service = StudentReviewService(

      rpcClient: rpc,

      currentUserId: () => 'user-a',

    );

    await service.submit(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-2',

      entityLabel: 'Physics',

      tagScores: const {'organization': 3},

    );

    await service.clearAll();

    final cached = await service.loadCachedMyReview(

      entityType: ReviewEntityType.subject,

      entityId: 'sub-2',

      entityLabel: 'Physics',

    );

    expect(cached, isNull);

  });

}

