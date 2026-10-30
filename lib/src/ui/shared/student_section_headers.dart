import 'package:lottie/lottie.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../schedule/widgets/calendar_icon_button.dart';

// Original screen headers, shared verbatim between account and guest shells.
class StudentInfoHeader extends StatelessWidget {
  final String subtitle;
  final IconData sectionIcon;
  final VoidCallback onSectionTap;
  final VoidCallback onInfoTap;

  const StudentInfoHeader({
    required this.subtitle,
    this.sectionIcon = Icons.school_outlined,
    required this.onSectionTap,
    required this.onInfoTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).height < 760;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.colorScheme.primary.withValues(alpha: 0.12),
              ],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                  diameter: 140,
                  color: theme.colorScheme.primary.withValues(alpha: 0.10),
                ),
              ),
              Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                  diameter: 160,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          bottom: false,
          child: SizedBox.expand(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 6),
              child: Align(
                alignment: Alignment(-1, compact ? 0.08 : 0.18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(compact ? 10 : 12),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.85),
                            blurRadius: 8,
                            offset: const Offset(-2, -2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.lightbulb_outline_rounded,
                        color: theme.colorScheme.primary,
                        size: compact ? 26 : 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'База',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: compact ? 30 : null,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                              height: 1.05,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: compact ? 2 : 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: (compact
                                    ? theme.textTheme.bodySmall
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                              color: Colors.black.withValues(alpha: 0.64),
                              height: 1.12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _HeaderActionButton(
                      icon: Icons.info_outline_rounded,
                      onTap: onInfoTap,
                    ),
                    const SizedBox(width: 8),
                    _HeaderActionButton(
                      icon: sectionIcon,
                      onTap: onSectionTap,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class StudentLearningHeader extends StatelessWidget {
  final Widget? trailing;
  const StudentLearningHeader({this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).height < 760;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                theme.colorScheme.primary.withOpacity(0.06),
                theme.colorScheme.primary.withOpacity(0.12),
              ],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                  diameter: 140,
                  color: theme.colorScheme.primary.withOpacity(0.10),
                ),
              ),
              Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                  diameter: 160,
                  color: Colors.white.withOpacity(0.55),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          bottom: false,
          child: SizedBox.expand(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 6),
              child: Align(
                alignment: Alignment(-1, compact ? 0.08 : 0.18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(compact ? 10 : 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.10),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.white.withOpacity(0.85),
                            blurRadius: 8,
                            offset: const Offset(-2, -2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.groups_rounded,
                        color: theme.colorScheme.primary,
                        size: compact ? 26 : 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Команды',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: compact ? 30 : null,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                              height: 1.05,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withOpacity(0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: compact ? 2 : 4),
                          Text(
                            'Чат и задания',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: (compact
                                    ? theme.textTheme.bodySmall
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                              color: Colors.black.withOpacity(0.64),
                              height: 1.12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class StudentScheduleHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  // НОВОЕ:
  final DateTime day;
  final List<Color> Function(DateTime) eventColors;
  final Map<Color, String>? legendItems;
  final ValueChanged<DateTime> onDatePicked;

  final Future<void> Function(DateTime)? onEnsureMonthLoaded;

  final WidgetBuilder menuBuilder;

  const StudentScheduleHeader({
    required this.title,
    required this.subtitle,
    required this.day,
    required this.eventColors,
    required this.onDatePicked,
    this.legendItems,
    this.onEnsureMonthLoaded,
    required this.menuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).height < 760;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white,
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.colorScheme.primary.withValues(alpha: 0.12),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(children: [
            Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                    diameter: 140,
                    color: theme.colorScheme.primary.withValues(alpha: 0.10))),
            Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                    diameter: 160,
                    color: Colors.white.withValues(alpha: 0.55))),
          ]),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 6),
            child: Align(
              alignment: Alignment(-1, compact ? 0.08 : 0.18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CalendarIconButton(
                    day: day,
                    eventColors: eventColors,
                    legendItems: legendItems,
                    onPicked: onDatePicked,
                    onEnsureMonthLoaded:
                        onEnsureMonthLoaded ?? (DateTime _) async {},
                  ),
                  SizedBox(width: compact ? 12 : 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                            fontSize: compact ? 30 : null,
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.05,
                            shadows: [
                              Shadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3)
                            ],
                          ),
                        ),
                        SizedBox(height: compact ? 2 : 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (compact
                                  ? Theme.of(context).textTheme.bodySmall
                                  : Theme.of(context).textTheme.bodyMedium)
                              ?.copyWith(
                            color: Colors.black.withValues(alpha: 0.64),
                            height: 1.12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  menuBuilder(context),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderActionButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.86),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon, color: theme.colorScheme.primary),
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter;
  final Color color;

  const _GlowCircle({
    required this.diameter,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }
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
      elevation: 18,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: primary.withValues(alpha: 0.08)),
      ),
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
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primary.withValues(alpha: 0.10)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: active ? primary : const Color(0xFF111827),
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF6B7280),
                  height: 1.1,
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
            width: 180, height: 180, repeat: true, animate: animate),
        const SizedBox(height: 12),
        Text(message, style: const TextStyle(fontSize: 14, color: Colors.grey)),
      ]),
    );
  }
}
