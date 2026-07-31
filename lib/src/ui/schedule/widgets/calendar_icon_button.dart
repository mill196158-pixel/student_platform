import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Иконка-календарь, открывающая КАСТОМНЫЙ month-picker:
/// • iOS-подобная сетка 6×7 (ПН–ВС)
/// • стрелки навигации (долгий тап — листает на год)
/// • точки-индикаторы занятий (через [eventColors])
/// • кнопки «Сегодня» / «Отмена»
/// • опциональная легенда
///
/// ВАЖНО: чтобы точки сразу были видны при перелистывании месяцев,
/// передай [onEnsureMonthLoaded]: (monthStart) => await _loadMonth(monthStart)
class CalendarIconButton extends StatelessWidget {
  final DateTime day;
  final List<Color> Function(DateTime) eventColors;
  final Map<Color, String>? legendItems;
  final ValueChanged<DateTime> onPicked;

  /// Родитель должен подгрузить данные для месяца (1-е число месяца)
  /// и вернуть Future. Виджет ждёт (await) и только потом перерисовывает сетку.
  final Future<void> Function(DateTime monthStart) onEnsureMonthLoaded;

  /// Ограничения периода выбора
  final DateTime? firstDate;
  final DateTime? lastDate;

  /// Внешний размер круглой иконки
  final double size;

  const CalendarIconButton({
    super.key,
    required this.day,
    required this.eventColors,
    required this.onPicked,
    required this.onEnsureMonthLoaded, // делаем обязательным, чтобы не забыть
    this.legendItems,
    this.firstDate,
    this.lastDate,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Future<void> _openCustomSheet() async {
      final picked = await showModalBottomSheet<DateTime>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: theme.colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) {
          return _CalendarPickerSheet(
            initialDay: day,
            eventColors: eventColors,
            legendItems: legendItems,
            firstDate: firstDate ?? DateTime(DateTime.now().year - 1, 1, 1),
            lastDate:  lastDate  ?? DateTime(DateTime.now().year + 2, 12, 31),
            onEnsureMonthLoaded: onEnsureMonthLoaded,
          );
        },
      );
      if (picked != null) onPicked(picked);
    }

    return InkWell(
      onTap: _openCustomSheet,
      borderRadius: BorderRadius.circular(100),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.10),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 4)),
            BoxShadow(color: Colors.white.withOpacity(0.85), blurRadius: 8, offset: const Offset(-2, -2)),
          ],
        ),
        child: Icon(Icons.calendar_today_rounded, color: theme.colorScheme.primary, size: size * 0.6),
      ),
    );
  }
}

/// Внутренний виджет кастомного month-picker’а
class _CalendarPickerSheet extends StatefulWidget {
  final DateTime initialDay;
  final List<Color> Function(DateTime) eventColors;
  final Map<Color, String>? legendItems;
  final DateTime firstDate;
  final DateTime lastDate;
  final Future<void> Function(DateTime monthStart) onEnsureMonthLoaded;

  const _CalendarPickerSheet({
    required this.initialDay,
    required this.eventColors,
    required this.firstDate,
    required this.lastDate,
    required this.onEnsureMonthLoaded,
    this.legendItems,
  });

  @override
  State<_CalendarPickerSheet> createState() => _CalendarPickerSheetState();
}

class _CalendarPickerSheetState extends State<_CalendarPickerSheet> {
  late DateTime _visibleMonth; // всегда 1-е число месяца
  late DateTime _selected;     // выбранный день
  bool _loadingMonth = false;

  @override
  void initState() {
    super.initState();
    _selected = _stripTime(widget.initialDay);
    _visibleMonth = DateTime(_selected.year, _selected.month, 1);

    // обеспечить данные для первого видимого месяца (сразу отрисуем точки)
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureMonthAndRefresh());
  }

  DateTime _stripTime(DateTime d) => DateTime(d.year, d.month, d.day);
  bool _sameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  List<DateTime> _daysGrid(DateTime monthAnchor) {
    final first = DateTime(monthAnchor.year, monthAnchor.month, 1);
    // ПН=1..ВС=7 → смещение от понедельника (0..6)
    final int shift = (first.weekday + 6) % 7;
    final start = first.subtract(Duration(days: shift));
    return List.generate(42, (i) => DateTime(start.year, start.month, start.day + i)); // 6×7
  }

  bool _isInRange(DateTime d) => !d.isBefore(widget.firstDate) && !d.isAfter(widget.lastDate);

  Future<void> _ensureMonthAndRefresh() async {
    setState(() => _loadingMonth = true);
    // ждём, пока родитель подтянет расписание на этот месяц
    await widget.onEnsureMonthLoaded(_visibleMonth);
    if (mounted) setState(() => _loadingMonth = false);
  }

  Future<void> _shiftMonth(int delta) async {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta, 1);
    });
    await _ensureMonthAndRefresh();
  }

  String _monthName(int m) {
    const ru = ['Январь','Февраль','Март','Апрель','Май','Июнь','Июль','Август','Сентябрь','Октябрь','Ноябрь','Декабрь'];
    return ru[m - 1];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = _daysGrid(_visibleMonth);
    const daysShort = ['ПН','ВТ','СР','ЧТ','ПТ','СБ','ВС'];
    final maxHeight = math.min(MediaQuery.of(context).size.height * 0.86, 640.0);

    return SizedBox(
      height: maxHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          children: [
            // grab handle
            Container(
              width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: theme.dividerColor, borderRadius: BorderRadius.circular(100)),
            ),

            // HEADER: стрелки + анимированный заголовок месяца
            Row(
              children: [
                _HeaderArrow(
                  icon: Icons.chevron_left,
                  tooltip: 'Предыдущий месяц',
                  onTap: () => _shiftMonth(-1),
                  onLongPress: () => _shiftMonth(-12),
                ),
                Expanded(
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutQuad,
                      switchOutCurve: Curves.easeInQuad,
                      transitionBuilder: (child, anim) => SlideTransition(
                        position: Tween<Offset>(begin: const Offset(0.0, .3), end: Offset.zero).animate(anim),
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: Text(
                        key: ValueKey('${_visibleMonth.year}-${_visibleMonth.month}'),
                        '${_monthName(_visibleMonth.month)} ${_visibleMonth.year}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800, color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                ),
                _HeaderArrow(
                  icon: Icons.chevron_right,
                  tooltip: 'Следующий месяц',
                  onTap: () => _shiftMonth(1),
                  onLongPress: () => _shiftMonth(12),
                ),
              ],
            ),

            const SizedBox(height: 6),

            // Weekdays
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(7, (i) =>
                Expanded(
                  child: Center(
                    child: Text(
                      daysShort[i],
                      style: theme.textTheme.labelSmall?.copyWith(color: Colors.black.withOpacity(0.60)),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 6),

            // GRID (с полупрозрачным лоадером поверх, пока месяц грузится)
            Expanded(
              child: Stack(
                children: [
                  GridView.builder(
                    padding: const EdgeInsets.only(top: 4),
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: days.length,
                    itemBuilder: (_, i) {
                      final d = days[i];
                      final inThisMonth = d.month == _visibleMonth.month;
                      final isSelected  = _sameDate(d, _selected);
                      final isToday     = _sameDate(d, _stripTime(DateTime.now()));
                      final enabled     = _isInRange(d);

                      // ВАЖНО: точки вычисляем по функциям родителя — после await они уже актуальные
                      final dots = widget.eventColors(d);

                      Color fg = Colors.black;
                      double opacity = inThisMonth ? 1.0 : 0.45;
                      if (!enabled) opacity = 0.25;

                      return InkWell(
                        onTap: enabled ? () {
                          setState(() => _selected = d);
                          Navigator.of(context).pop<DateTime>(d);
                        } : null,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: isSelected ? theme.colorScheme.primary : null,
                            border: Border.all(
                              color: isSelected
                                  ? theme.colorScheme.primary
                                  : (isToday ? theme.colorScheme.primary.withOpacity(0.55) : theme.dividerColor),
                            ),
                            boxShadow: isSelected
                                ? [BoxShadow(color: theme.colorScheme.primary.withOpacity(0.18), blurRadius: 10, offset: const Offset(0, 4))]
                                : null,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '${d.day}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: isSelected ? theme.colorScheme.onPrimary : fg.withOpacity(opacity),
                                  fontWeight: isSelected ? FontWeight.w800 : (isToday ? FontWeight.w700 : FontWeight.w500),
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                height: 8,
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 150),
                                  opacity: dots.isNotEmpty ? 1 : 0.35,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: dots.take(3).map((c) => Container(
                                      width: 6, height: 6, margin: const EdgeInsets.symmetric(horizontal: 1.5),
                                      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                                    )).toList(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  if (_loadingMonth)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Legend (optional)
            if ((widget.legendItems ?? {}).isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: widget.legendItems!.entries.map((e) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: e.key, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(e.value, style: theme.textTheme.labelMedium?.copyWith(color: Colors.black)),
                    ],
                  )).toList(),
                ),
              ),

            // Footer
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Отмена'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final now = DateTime.now();
                    final t = DateTime(now.year, now.month, now.day);
                    if (_isInRange(t)) {
                      final start = DateTime(t.year, t.month, 1);
                      if (!_sameDate(start, _visibleMonth)) {
                        setState(() => _visibleMonth = start);
                        await _ensureMonthAndRefresh();
                      }
                      if (mounted) Navigator.of(context).pop<DateTime>(t);
                    }
                  },
                  child: const Text('Сегодня'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderArrow extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _HeaderArrow({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.all(6.0),
        child: Icon(icon),
      ),
    );
  }
}
