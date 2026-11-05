import 'package:flutter/material.dart';

import 'package:student_ui/student_ui.dart';
import '../common/friendly_empty_state.dart';

import '../profile/student_review_service.dart';

/// Minimal leave/view review surface for one teacher or subject entity.

class EntityReviewScreen extends StatefulWidget {
  const EntityReviewScreen({
    super.key,
    required this.entityType,
    required this.entityId,
    required this.entityLabel,
    this.reviewService,
  });

  final ReviewEntityType entityType;

  final String entityId;

  final String entityLabel;

  final StudentReviewService? reviewService;

  @override
  State<EntityReviewScreen> createState() => _EntityReviewScreenState();
}

class _EntityReviewScreenState extends State<EntityReviewScreen> {
  late final StudentReviewService _service;

  EntityReviewSummaryResult _summary =
      const EntityReviewSummaryResult(intentionallyEmpty: true);

  StudentReviewCardPayload? _myReview;

  bool _loading = true;
  bool _loadError = false;

  bool _submitting = false;

  final _bodyController = TextEditingController();

  final Map<String, int> _tagScores = {};

  @override
  void initState() {
    super.initState();

    _service = widget.reviewService ?? StudentReviewService();

    _bootstrap();
  }

  @override
  void dispose() {
    _bodyController.dispose();

    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });

    final summaryFuture = _service.loadSummary(
      entityType: widget.entityType,
      entityId: widget.entityId,
    );

    final myReviewFuture = _service.loadCachedMyReview(
      entityType: widget.entityType,
      entityId: widget.entityId,
      entityLabel: widget.entityLabel,
    );

    try {
      final results =
          await Future.wait<Object?>([summaryFuture, myReviewFuture]);
      final summary = results[0] as EntityReviewSummaryResult;
      final myReview = results[1] as StudentReviewCardPayload?;
      if (!mounted) return;
      if (summary.loadError) {
        setState(() {
          _loading = false;
          _loadError = true;
        });
        return;
      }
      if (myReview != null) {
        _tagScores
          ..clear()
          ..addAll(myReview.tagScores);
        _bodyController.text = myReview.bodyPreview ?? '';
      }
      setState(() {
        _summary = summary;
        _myReview = myReview;
        _loading = false;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _loadError = true;
        });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;

    setState(() => _submitting = true);

    try {
      final result = await _service.submit(
        entityType: widget.entityType,
        entityId: widget.entityId,
        entityLabel: widget.entityLabel,
        tagScores: Map<String, int>.from(_tagScores),
        bodyText:
            _summary.summary?.textEnabled == true ? _bodyController.text : '',
      );

      if (!mounted) return;

      if (!result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.errorMessage ?? 'Не удалось отправить отзыв',
            ),
          ),
        );

        return;
      }

      final payload = StudentReviewCardPayload(
        entityType: widget.entityType,
        entityLabel: widget.entityLabel,
        tagScores: Map<String, int>.from(_tagScores),
        bodyPreview: _summary.summary?.textEnabled != true ||
                _bodyController.text.trim().isEmpty
            ? null
            : _bodyController.text.trim(),
        moderationStatus: result.moderationStatus,
      );

      setState(() => _myReview = payload);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.isDemoFallback
                ? 'Отзыв сохранён локально (Пример)'
                : result.isPendingModeration
                    ? 'Отзыв отправлен на модерацию'
                    : 'Отзыв отправлен',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = reviewTagCodesFor(widget.entityType);
    return Scaffold(
      appBar: AppBar(title: Text('Отзыв · ${widget.entityType.labelRu}')),
      body: _loading
          ? const Center(child: ProductLoadingIndicator.page())
          : _loadError
              ? Center(
                  child: SingleChildScrollView(
                      child: FriendlyEmptyState(
                          title: 'Не удалось загрузить отзыв',
                          subtitle:
                              'Проверьте соединение и попробуйте ещё раз.',
                          fallbackIcon: Icons.cloud_off_outlined,
                          animationHeight: 72,
                          action: OutlinedButton.icon(
                              onPressed: _bootstrap,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Повторить')))))
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        Text(widget.entityLabel,
                            style: theme.textTheme.titleLarge),
                        const SizedBox(height: 24),
                        if (!_summary.hideSummary) ...[
                          _SummaryPanel(
                              summary: _summary.displaySummary,
                              showDemoBadge: _summary.isDemoFallback &&
                                  _summary.rpcUnavailable),
                          const SizedBox(height: 24),
                        ],
                        if (_myReview != null) ...[
                          StudentReviewCard(
                              payload: _myReview!,
                              showDemoBadge: _summary.isDemoFallback),
                          const SizedBox(height: 24),
                        ],
                        Text('Ваш отзыв', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(
                            'Выберите оценки от 1 до 5. Можно оценить только часть характеристик.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 20),
                        for (final tag in tags) ...[
                          _TagScoreChip(
                              label: reviewTagLabelsRu[tag] ?? tag,
                              value: _tagScores[tag],
                              onSelected: (value) => setState(() {
                                    if (value == null) {
                                      _tagScores.remove(tag);
                                    } else {
                                      _tagScores[tag] = value;
                                    }
                                  })),
                          const SizedBox(height: 16),
                        ],
                        if (_summary.summary?.textEnabled == true) ...[
                          const SizedBox(height: 8),
                          TextField(
                              controller: _bodyController,
                              maxLines: 4,
                              maxLength: 1000,
                              decoration: const InputDecoration(
                                  labelText: 'Комментарий',
                                  hintText: 'Необязательно',
                                  alignLabelWithHint: true)),
                        ],
                        const SizedBox(height: 8),
                        Text('Оценки сохранятся после отправки отзыва.',
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: ProductLoadingIndicator())
                                : const Icon(Icons.send_rounded),
                            label: const Text('Отправить отзыв')),
                      ],
                    ),
                  ),
                ),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.summary,
    required this.showDemoBadge,
  });

  final EntityReviewSummary summary;

  final bool showDemoBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final tags = summary.tagAverages.entries
        .map(
          (e) =>
              '${reviewTagLabelsRu[e.key] ?? e.key}: ${e.value.toStringAsFixed(1)}',
        )
        .join(' · ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Сводка отзывов',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (showDemoBadge)
                  Text(
                    'Пример',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: const Color(0xFF6B21A8),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Активных: ${summary.activeCount}'),
            if (tags.isNotEmpty) Text(tags),
          ],
        ),
      ),
    );
  }
}

class _TagScoreChip extends StatelessWidget {
  const _TagScoreChip(
      {required this.label, required this.value, required this.onSelected});
  final String label;
  final int? value;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      borderRadius: ProductTheme.selectionMenuRadius,
      elevation: ProductTheme.selectionMenuElevation,
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      key: ValueKey('review-score-$label-$value'),
      initialValue: value ?? 0,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: 0, child: Text('Не оценивать')),
        for (var score = 1; score <= 5; score++)
          DropdownMenuItem(value: score, child: Text('$score из 5')),
      ],
      onChanged: (score) =>
          onSelected(score == null || score == 0 ? null : score),
    );
  }
}
