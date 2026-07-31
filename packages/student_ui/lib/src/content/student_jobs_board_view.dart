import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'student_vacancy_card.dart';
import 'student_vacancy_detail_sheet.dart';
import 'vacancy_models.dart';

Uint8List? _vacancyBytes(List<int>? raw) {
  if (raw == null || raw.isEmpty) return null;
  return raw is Uint8List ? raw : Uint8List.fromList(raw);
}

/// Presentation-only jobs board chrome for Admin phone preview / Mobile.
///
/// No Supabase/routing/service imports.
class StudentJobsBoardView extends StatelessWidget {
  const StudentJobsBoardView({
    super.key,
    required this.cards,
    this.selectedId,
    this.onOpenDetail,
    this.detailPayload,
    this.onBack,
    this.heroSubtitle,
    this.emptyMessage = 'Вакансии пока пусты',
    this.showProposeActions = false,
    this.onProposeVacancy,
    this.onMySubmissions,
  });

  final List<ManagedVacancyCard> cards;
  final String? selectedId;
  final ValueChanged<String>? onOpenDetail;

  /// When non-null, show detail with back using [StudentVacancyDetailSheet].
  final ManagedVacancyCard? detailPayload;
  final VoidCallback? onBack;

  final String? heroSubtitle;
  final String emptyMessage;
  final bool showProposeActions;
  final VoidCallback? onProposeVacancy;
  final VoidCallback? onMySubmissions;

  static const _bg = Color(0xFFFAF8FC);
  static const _title = Color(0xFF111827);
  static const _lavenderStart = Color(0xFFDCD0FA);
  static const _lavenderEnd = Color(0xFFC9B8F3);
  static const _accent = Color(0xFF5B4B8A);

  @override
  Widget build(BuildContext context) {
    if (detailPayload != null) {
      return _JobsDetailView(
        card: detailPayload!,
        onBack: onBack,
      );
    }

    return ColoredBox(
      color: _bg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        children: [
          _JobsHeroCard(
            subtitle: heroSubtitle ??
                'Подработки, стажировки и проектные задачи для студентов.',
            showProposeActions: showProposeActions,
            onProposeVacancy: onProposeVacancy,
            onMySubmissions: onMySubmissions,
          ),
          const SizedBox(height: 10),
          if (cards.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              child: Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.black54,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            )
          else ...[
            Text(
              'Свежие предложения',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _title,
                  ),
            ),
            const SizedBox(height: 8),
            for (final card in cards) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: card.id == selectedId
                      ? Border.all(color: _accent, width: 2)
                      : null,
                ),
                child: StudentVacancyCard(
                  payload: card.payload,
                  showDemoBadge: card.showDemoBadge,
                  expiresLabel: vacancyExpiresLabel(card.expiresAt),
                  hasContacts: card.hasContacts,
                  logoBytes: _vacancyBytes(card.logoBytes),
                  coverBytes: _vacancyBytes(card.coverBytes),
                  backgroundBytes: _vacancyBytes(card.backgroundBytes),
                  onTap: onOpenDetail == null
                      ? null
                      : () => onOpenDetail!(card.id),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }
}

class _JobsDetailView extends StatelessWidget {
  const _JobsDetailView({
    required this.card,
    this.onBack,
  });

  final ManagedVacancyCard card;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: StudentJobsBoardView._bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Назад',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    card.payload.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: StudentJobsBoardView._title,
                        ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StudentVacancyDetailSheet(
              card: card,
              showDemoBadge: card.showDemoBadge,
              logoBytes: _vacancyBytes(card.logoBytes),
              coverBytes: _vacancyBytes(card.coverBytes),
              backgroundBytes: _vacancyBytes(card.backgroundBytes),
              showCloseButton: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _JobsHeroCard extends StatelessWidget {
  const _JobsHeroCard({
    required this.subtitle,
    this.showProposeActions = false,
    this.onProposeVacancy,
    this.onMySubmissions,
  });

  final String subtitle;
  final bool showProposeActions;
  final VoidCallback? onProposeVacancy;
  final VoidCallback? onMySubmissions;

  static const _minTouch = 40.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w800,
      fontSize: 12,
      height: 1.1,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            StudentJobsBoardView._lavenderStart,
            StudentJobsBoardView._lavenderEnd,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: StudentJobsBoardView._lavenderEnd.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.work_outline_rounded,
                  size: 18,
                  color: StudentJobsBoardView._accent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Доска вакансий',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: StudentJobsBoardView._title,
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF374151),
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showProposeActions) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: _minTouch),
                    child: Tooltip(
                      message: 'Предложить вакансию',
                      child: FilledButton.icon(
                        onPressed: onProposeVacancy,
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('Предложить'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, _minTouch),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: actionStyle,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: _minTouch),
                    child: OutlinedButton.icon(
                      onPressed: onMySubmissions,
                      icon: const Icon(Icons.inbox_outlined, size: 16),
                      label: const Text('Мои заявки'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, _minTouch),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: actionStyle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
