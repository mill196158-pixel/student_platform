import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';

class NewsCard extends StatelessWidget {
  final HomeNewsItem news;
  final VoidCallback onTap;

  const NewsCard({
    super.key,
    required this.news,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = _accentColor(news.type);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 236,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF182331) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color:
                isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.06),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.18 : 0.12),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(_icon(news.type), color: accent),
                ),
                const Spacer(),
                Icon(Icons.chevron_right_rounded, color: accent),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              news.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.12,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              news.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.64),
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _accentColor(HomeNewsType type) {
    switch (type) {
      case HomeNewsType.update:
        return const Color(0xFF7C63D8);
      case HomeNewsType.diary:
        return const Color(0xFF8A72D8);
      case HomeNewsType.materials:
        return const Color(0xFF2F9D84);
      case HomeNewsType.assignments:
        return const Color(0xFFB58B3B);
    }
  }

  IconData _icon(HomeNewsType type) {
    switch (type) {
      case HomeNewsType.update:
        return Icons.auto_awesome_rounded;
      case HomeNewsType.diary:
        return Icons.edit_note_rounded;
      case HomeNewsType.materials:
        return Icons.folder_copy_outlined;
      case HomeNewsType.assignments:
        return Icons.assignment_turned_in_outlined;
    }
  }
}
