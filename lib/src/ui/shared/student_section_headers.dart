import 'package:lottie/lottie.dart';
import 'package:flutter/material.dart';
import '../schedule/widgets/calendar_icon_button.dart';

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(
      {required this.title,
      required this.subtitle,
      required this.leading,
      this.actions = const []});
  final String title, subtitle;
  final Widget leading;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
            bottom: false,
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(children: [
                  leading,
                  const SizedBox(width: 16),
                  Expanded(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 4),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall)
                      ])),
                  ...actions
                ]))));
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon(this.icon);
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: .45),
          borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: Theme.of(context).colorScheme.primary));
}

class StudentInfoHeader extends StatelessWidget {
  const StudentInfoHeader(
      {required this.subtitle,
      this.sectionIcon = Icons.school_outlined,
      required this.onSectionTap,
      required this.onInfoTap});
  final String subtitle;
  final IconData sectionIcon;
  final VoidCallback onSectionTap, onInfoTap;
  @override
  Widget build(BuildContext context) => _SectionHeading(
          title: 'База',
          subtitle: subtitle,
          leading: const _SectionIcon(Icons.lightbulb_outline_rounded),
          actions: [
            IconButton(
                tooltip: 'О разделе',
                onPressed: onInfoTap,
                icon: const Icon(Icons.info_outline_rounded)),
            IconButton(
                tooltip: 'Выбрать раздел',
                onPressed: onSectionTap,
                icon: Icon(sectionIcon))
          ]);
}

class StudentLearningHeader extends StatelessWidget {
  const StudentLearningHeader({this.trailing});
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => _SectionHeading(
      title: 'Команды',
      subtitle: 'Чат и задания',
      leading: const _SectionIcon(Icons.groups_rounded),
      actions: [if (trailing != null) trailing!]);
}

class StudentScheduleHeader extends StatelessWidget {
  const StudentScheduleHeader(
      {required this.title,
      required this.subtitle,
      required this.day,
      required this.eventColors,
      required this.onDatePicked,
      this.legendItems,
      this.onEnsureMonthLoaded,
      required this.menuBuilder});
  final String title, subtitle;
  final DateTime day;
  final List<Color> Function(DateTime) eventColors;
  final Map<Color, String>? legendItems;
  final ValueChanged<DateTime> onDatePicked;
  final Future<void> Function(DateTime)? onEnsureMonthLoaded;
  final WidgetBuilder menuBuilder;
  @override
  Widget build(BuildContext context) => _SectionHeading(
      title: title,
      subtitle: subtitle,
      leading: CalendarIconButton(
          day: day,
          eventColors: eventColors,
          legendItems: legendItems,
          onPicked: onDatePicked,
          onEnsureMonthLoaded: onEnsureMonthLoaded ?? (DateTime _) async {}),
      actions: [menuBuilder(context)]);
}

class StudentScheduleMenu extends StatelessWidget {
  final ValueChanged<String> onSelected;
  final bool weekMode;

  const StudentScheduleMenu({
    required this.onSelected,
    required this.weekMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return PopupMenuButton<String>(
      tooltip: 'Действия с расписанием',
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      constraints: const BoxConstraints(minWidth: 244),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'today',
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: weekMode
              ? const _ScheduleMenuItem(
                  icon: Icons.date_range_rounded,
                  title: 'Текущая неделя',
                  subtitle: 'Вернуться к этой неделе',
                )
              : const _ScheduleMenuItem(
                  icon: Icons.today_rounded,
                  title: 'Сегодня',
                  subtitle: 'Вернуться к текущему дню',
                ),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          value: 'view_day',
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _ScheduleMenuItem(
            icon: Icons.calendar_view_day_rounded,
            title: 'По дням',
            subtitle: 'Подробно, один день',
            active: !weekMode,
          ),
        ),
        PopupMenuItem(
          value: 'view_week',
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _ScheduleMenuItem(
            icon: Icons.calendar_view_week_rounded,
            title: 'По неделям',
            subtitle: 'Обзор всей недели',
            active: weekMode,
          ),
        ),
      ],
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primary.withValues(alpha: 0.10)),
        ),
        child: Icon(Icons.more_horiz_rounded, color: primary, size: 26),
      ),
    );
  }
}

class _ScheduleMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;

  const _ScheduleMenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: primary.withValues(alpha: active ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: active ? primary : theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
        if (active) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_circle_rounded, color: primary, size: 20),
        ],
      ],
    );
  }
}

class StudentScheduleEmptyState extends StatelessWidget {
  final String message;
  const StudentScheduleEmptyState(
      {this.message = 'Здесь пока пусто', this.animate = true});
  final bool animate;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Lottie.asset('assets/lottie/cat_sleeping.json',
            width: 180,
            height: 180,
            repeat: !MediaQuery.disableAnimationsOf(context),
            animate: animate && !MediaQuery.disableAnimationsOf(context)),
        const SizedBox(height: 12),
        Text(message,
            style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
