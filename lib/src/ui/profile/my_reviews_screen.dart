import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import '../info/entity_review_screen.dart';
import 'student_review_service.dart';

/// Lists the student's own entity reviews from RPC or local cache.
class MyReviewsScreen extends StatefulWidget {
  const MyReviewsScreen({
    super.key,
    this.reviewService,
  });

  final StudentReviewService? reviewService;

  @override
  State<MyReviewsScreen> createState() => _MyReviewsScreenState();
}

class _MyReviewsScreenState extends State<MyReviewsScreen> {
  static const _demoEntityId = '11111111-1111-1111-1111-111111111111';

  late final StudentReviewService _service;
  MyEntityReviewsResult _result = const MyEntityReviewsResult();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _service = widget.reviewService ?? StudentReviewService();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await _service.loadMyReviews();
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  void _openReview(MyEntityReviewItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EntityReviewScreen(
          entityType: item.entityType,
          entityId: item.entityId,
          entityLabel: item.entityLabel,
          reviewService: _service,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _result.items;
    final showDemoFallback =
        _result.isDemoFallback && _result.rpcUnavailable && items.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Мои отзывы')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Отзывы о преподавателях и предметах',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'После модерации одобренного отзыва начисляется 1 балл.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF6B7280),
                        ),
                  ),
                  const SizedBox(height: 16),
                  if (items.isEmpty && !showDemoFallback)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('Вы ещё не оставляли отзывов'),
                      ),
                    ),
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: StudentReviewCard(
                        payload: item.toCardPayload(),
                        onTap: () => _openReview(item),
                      ),
                    ),
                  if (showDemoFallback) ...[
                    StudentReviewCard(
                      payload: StudentReviewCardPayload.demoPending,
                      showDemoBadge: true,
                      onTap: () => _openReview(
                        MyEntityReviewItem(
                          reviewId: 'demo-subject',
                          entityType: ReviewEntityType.subject,
                          entityId: _demoEntityId,
                          entityLabel:
                              StudentReviewCardPayload.demoPending.entityLabel,
                          tagScores:
                              StudentReviewCardPayload.demoPending.tagScores,
                          bodyPreview:
                              StudentReviewCardPayload.demoPending.bodyPreview,
                          moderationStatus: ReviewModerationStatus.pending,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    StudentReviewCard(
                      payload: StudentReviewCardPayload.demoTeacher,
                      showDemoBadge: true,
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
