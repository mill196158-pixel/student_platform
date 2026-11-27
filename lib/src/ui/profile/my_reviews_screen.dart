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
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _service = widget.reviewService ?? StudentReviewService();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final result = await _service.loadMyReviews();
      if (!mounted) return;
      setState(() => _result = result);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Мои отзывы'), centerTitle: true),
      body: _loading
          ? const Center(child: ProductLoadingIndicator.page())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                children: [
                  if (_loadFailed)
                    _ReviewsMessage(
                      icon: Icons.refresh_rounded,
                      title: 'Не удалось загрузить отзывы',
                      action: FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('Повторить'),
                      ),
                    )
                  else ...[
                    Text(
                      'Отзывы проходят проверку перед публикацией.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (items.isEmpty && !showDemoFallback)
                      const _ReviewsMessage(
                        icon: Icons.rate_review_outlined,
                        title: 'Вы ещё не оставляли отзывов',
                        detail:
                            'Здесь появятся ваши отзывы о преподавателях и предметах.',
                      ),
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: StudentReviewCard(
                          payload: item.toCardPayload(),
                          inProfileList: true,
                          onTap: () => _openReview(item),
                        ),
                      ),
                    if (showDemoFallback) ...[
                      StudentReviewCard(
                        payload: StudentReviewCardPayload.demoPending,
                        inProfileList: true,
                        showDemoBadge: true,
                        onTap: () => _openReview(
                          MyEntityReviewItem(
                            reviewId: 'demo-subject',
                            entityType: ReviewEntityType.subject,
                            entityId: _demoEntityId,
                            entityLabel: StudentReviewCardPayload
                                .demoPending.entityLabel,
                            tagScores:
                                StudentReviewCardPayload.demoPending.tagScores,
                            bodyPreview: StudentReviewCardPayload
                                .demoPending.bodyPreview,
                            moderationStatus: ReviewModerationStatus.pending,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const StudentReviewCard(
                        payload: StudentReviewCardPayload.demoTeacher,
                        inProfileList: true,
                        showDemoBadge: true,
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}

class _ReviewsMessage extends StatelessWidget {
  const _ReviewsMessage({
    required this.icon,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 40, 8, 24),
      child: Column(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 28),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 16),
            action!,
          ],
        ],
      ),
    );
  }
}
