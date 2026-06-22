import 'package:flutter/material.dart';

/// Компактный мини-календарь на 7 дней, с точками-индикаторами типов событий.
/// [eventColors] — вернёт список цветов (до 3) для конкретной даты.
class MiniCalendar extends StatelessWidget {
  final List<DateTime> weekDays;
  final DateTime selectedDay;
  final List<Color> Function(DateTime d) eventColors;
  final VoidCallback onPrevWeek;
  final VoidCallback onNextWeek;
  final ValueChanged<DateTime> onSelect;

  const MiniCalendar({
    super.key,
    required this.weekDays,
    required this.selectedDay,
    required this.eventColors,
    required this.onPrevWeek,
    required this.onNextWeek,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const daysShort = ['ПН','ВТ','СР','ЧТ','ПТ','СБ','ВС'];

    Widget arrow(IconData icon, VoidCallback onTap) => IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 22),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      splashRadius: 18,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Row(
        children: [
          arrow(Icons.chevron_left, onPrevWeek),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: weekDays.map((d) {
                final isSelected = d.year == selectedDay.year && d.month == selectedDay.month && d.day == selectedDay.day;
                final colors = eventColors(d);

                return GestureDetector(
                  onTap: () => onSelect(d),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(daysShort[d.weekday - 1],
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.black.withOpacity(0.72))),
                      const SizedBox(height: 6),
                      Container(
                        width: 36, height: 36, alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.isNotEmpty
                                ? theme.colorScheme.primary.withOpacity(0.55)
                                : theme.dividerColor,
                          ),
                          boxShadow: isSelected
                              ? [BoxShadow(color: theme.colorScheme.primary.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 4))]
                              : null,
                        ),
                        child: Text(
                          '${d.day}',
                          style: TextStyle(
                            color: isSelected ? theme.colorScheme.onPrimary : Colors.black,
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // до 3 цветных точек типов событий — фиксируем высоту,
                      // чтобы карточки дат не «прыгали», даже если точек нет
                      SizedBox(
                        width: 36,
                        height: 10,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: colors.take(3).map((c) => Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                            width: 6, height: 6,
                            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                          )).toList(),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          arrow(Icons.chevron_right, onNextWeek),
        ],
      ),
    );
  }
}

/// Небольшая легенда под календарём
class CalendarLegend extends StatelessWidget {
  final Map<Color, String> items;
  const CalendarLegend({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final chips = items.entries.map((e) => _LegendChip(color: e.key, text: e.value)).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Wrap(spacing: 10, runSpacing: 6, children: chips),
    );
  }
}

class _LegendChip extends StatelessWidget {
  final Color color;
  final String text;
  const _LegendChip({required this.color, required this.text});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.black)),
    ]);
  }
}
