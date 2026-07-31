import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DateSeparator extends StatelessWidget {
  final DateTime date;

  const DateSeparator({
    super.key,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    String dateText;
    if (messageDate == today) {
      dateText = 'Сегодня';
    } else if (messageDate == yesterday) {
      dateText = 'Вчера';
    } else {
      dateText = DateFormat('d MMMM yyyy', 'ru').format(date);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
            child: Text(
              dateText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}
