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
    this.activeCount,
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

  /// Override for stats row; defaults to [cards.length].
  final int? activeCount;

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

    final count = activeCount ?? cards.length;

    return ColoredBox(
      color: _bg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _JobsHeroCard(
            subtitle: heroSubtitle ??
                'Подработки, стажировки и проектные задачи для студентов.',
            showProposeActions: showProposeActions,
            onProposeVacancy: onProposeVacancy,
            onMySubmissions: onMySubmissions,
          ),
          const SizedBox(height: 12),
          _JobsStatsRow(activeCount: count),
          const SizedBox(height: 12),
          if (cards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.black54,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            )
          else ...[
            Text(
              'Свежие предложения',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _title,
                  ),
            ),
            const SizedBox(height: 10),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
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
            color: StudentJobsBoardView._lavenderEnd.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.work_outline_rounded,
                  color: StudentJobsBoardView._accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Доска вакансий',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: StudentJobsBoardView._title,
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF374151),
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (showProposeActions) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onProposeVacancy,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Предложить вакансию'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onMySubmissions,
                icon: const Icon(Icons.inbox_outlined),
                label: const Text('Мои заявки'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _JobsStatsRow extends StatelessWidget {
  const _JobsStatsRow({required this.activeCount});

  final int activeCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _JobStatPill(
            icon: Icons.flash_on_rounded,
            title: '$activeCount',
            subtitle: activeCount == 1 ? 'активная' : 'активных',
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: _JobStatPill(
            icon: Icons.verified_user_outlined,
            title: 'скоро',
            subtitle: 'модерация',
          ),
        ),
      ],
    );
  }
}

class _JobStatPill extends StatelessWidget {
  const _JobStatPill({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: StudentJobsBoardView._accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: StudentJobsBoardView._title,
                      ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
