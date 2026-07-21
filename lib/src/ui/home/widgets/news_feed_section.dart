import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';

class NewsFeedSection extends StatelessWidget {
  final List<HomeNewsItem> news;
  final ValueChanged<int> onNewsTap;

  const NewsFeedSection({
    super.key,
    required this.news,
    required this.onNewsTap,
  });

  @override
  Widget build(BuildContext context) {
    if (news.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 128,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: news.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                return _NewsFeedCard(
                  item: news[index],
                  onTap: () => onNewsTap(index),
                );
              },
            ),
          ),
          const SizedBox(height: 22),
        ],
      ),
    );
  }
}

class _NewsFeedCard extends StatelessWidget {
  final HomeNewsItem item;
  final VoidCallback onTap;

  const _NewsFeedCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = item.gradientColors.length >= 2
        ? item.gradientColors
        : const [Color(0xFFEDE7F6), Color(0xFFD9CCF5)];
    final accent = isDark ? colors.last : colors.first;
    final textColor = isDark ? Colors.white : const Color(0xFF1F2937);
    final cardColors = isDark
        ? colors
        : [
            Color.alphaBlend(colors.first.withValues(alpha: .62), Colors.white),
            Color.alphaBlend(colors.last.withValues(alpha: .50), Colors.white),
          ];

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26),
      child: Container(
        width: 156,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: cardColors,
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: .10)
                : colors.first.withValues(alpha: .38),
          ),
          boxShadow: [
            BoxShadow(
              color: (isDark ? Colors.black : colors.first)
                  .withValues(alpha: isDark ? .22 : .20),
              blurRadius: 18,
              offset: const Offset(0, 9),
            ),
          ],
        ),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.textScalerOf(context).clamp(
              minScaleFactor: 1,
              maxScaleFactor: 1.08,
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -12,
                bottom: -12,
                child: Icon(
                  item.icon,
                  size: 64,
                  color: accent.withValues(alpha: isDark ? 0.16 : 0.20),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: isDark ? .18 : .24),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(item.icon, color: accent, size: 19),
                  ),
                  const Spacer(),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w900,
                      fontSize: 14.5,
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: isDark ? 0.78 : 0.58),
                      fontWeight: FontWeight.w600,
                      fontSize: 10.5,
                      height: 1.12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
