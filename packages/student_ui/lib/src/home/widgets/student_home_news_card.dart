import 'package:flutter/material.dart';

import '../home_preview_models.dart';
import 'news_image_frame.dart';

class StudentHomeNewsFeed extends StatelessWidget {
  const StudentHomeNewsFeed({
    required this.news,
    required this.onNewsTap,
    this.selectedNewsId,
    this.adminHighlightColor,
    super.key,
  });

  final List<StudentHomeNews> news;
  final ValueChanged<int>? onNewsTap;
  final String? selectedNewsId;
  final Color? adminHighlightColor;

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
                final item = news[index];
                return StudentHomeNewsCard(
                  item: item,
                  onTap: onNewsTap == null ? null : () => onNewsTap!(index),
                  isSelected: item.id == selectedNewsId,
                  adminHighlightColor: adminHighlightColor,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class StudentHomeNewsCard extends StatefulWidget {
  const StudentHomeNewsCard({
    required this.item,
    this.onTap,
    this.isSelected = false,
    this.adminHighlightColor,
    super.key,
  });

  final StudentHomeNews item;
  final VoidCallback? onTap;
  final bool isSelected;
  final Color? adminHighlightColor;

  @override
  State<StudentHomeNewsCard> createState() => _StudentHomeNewsCardState();
}

class _StudentHomeNewsCardState extends State<StudentHomeNewsCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = widget.item.gradientColors.length >= 2
        ? widget.item.gradientColors
        : const [Color(0xFFEDE7F6), Color(0xFFD9CCF5)];
    final accent = isDark ? colors.last : colors.first;
    final showAdminHighlight =
        widget.adminHighlightColor != null && (_hovered || widget.isSelected);
    final borderColor = showAdminHighlight
        ? widget.adminHighlightColor!
        : isDark
            ? Colors.white.withValues(alpha: .10)
            : colors.first.withValues(alpha: .38);

    return MouseRegion(
      onEnter: widget.adminHighlightColor == null
          ? null
          : (_) => setState(() => _hovered = true),
      onExit: widget.adminHighlightColor == null
          ? null
          : (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(26),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 156,
          height: 128,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: borderColor,
              width: showAdminHighlight ? 1.35 : 1,
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
              textScaler: MediaQuery.textScalerOf(
                context,
              ).clamp(minScaleFactor: 1, maxScaleFactor: 1.08),
            ),
            child: _CardShell(
              item: widget.item,
              accent: accent,
              isDark: isDark,
              colors: colors,
            ),
          ),
        ),
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.item,
    required this.accent,
    required this.isDark,
    required this.colors,
  });

  final StudentHomeNews item;
  final Color accent;
  final bool isDark;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF1F2937);
    return switch (item.variant) {
      StudentHomeNewsVariant.gradientText => _GradientTextCard(
          item: item,
          accent: accent,
          textColor: textColor,
          isDark: isDark,
          colors: colors,
        ),
      StudentHomeNewsVariant.imageOnly => _ImageOnlyCard(
          item: item,
          colors: colors,
          isDark: isDark,
        ),
      StudentHomeNewsVariant.imageOverlay => _ImageOverlayCard(
          item: item,
          colors: colors,
        ),
      StudentHomeNewsVariant.imageWithText => _ImageWithTextCard(
          item: item,
          accent: accent,
          textColor: textColor,
          isDark: isDark,
          colors: colors,
        ),
    };
  }
}

class _GradientTextCard extends StatelessWidget {
  const _GradientTextCard({
    required this.item,
    required this.accent,
    required this.textColor,
    required this.isDark,
    required this.colors,
  });

  final StudentHomeNews item;
  final Color accent;
  final Color textColor;
  final bool isDark;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final cardColors = isDark
        ? colors
        : [
            Color.alphaBlend(colors.first.withValues(alpha: .62), Colors.white),
            Color.alphaBlend(colors.last.withValues(alpha: .50), Colors.white),
          ];

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: cardColors,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                _NewsTitle(item: item, color: textColor),
                const SizedBox(height: 5),
                _NewsSubtitle(item: item, color: textColor),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageOnlyCard extends StatelessWidget {
  const _ImageOnlyCard({
    required this.item,
    required this.colors,
    required this.isDark,
  });

  final StudentHomeNews item;
  final List<Color> colors;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // Full-bleed photo only — no padding, overlay, or decorative icon.
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child:
              _NewsImageBackground(item: item, colors: colors, isDark: isDark),
        ),
      ],
    );
  }
}

class _ImageOverlayCard extends StatelessWidget {
  const _ImageOverlayCard({
    required this.item,
    required this.colors,
  });

  final StudentHomeNews item;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final darken = item.overlayDarken.clamp(0.0, 0.9);
    // Layers: image → overlay → text. Image/overlay are Positioned.fill.
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: _NewsImageBackground(
            item: item,
            colors: colors,
            isDark: true,
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: darken * 0.35),
                  Colors.black.withValues(alpha: darken),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              _NewsTitle(item: item, color: Colors.white),
              const SizedBox(height: 5),
              _NewsSubtitle(item: item, color: Colors.white, strong: true),
            ],
          ),
        ),
      ],
    );
  }
}

class _ImageWithTextCard extends StatelessWidget {
  const _ImageWithTextCard({
    required this.item,
    required this.accent,
    required this.textColor,
    required this.isDark,
    required this.colors,
  });

  final StudentHomeNews item;
  final Color accent;
  final Color textColor;
  final bool isDark;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF1A2330) : Colors.white;
    return ColoredBox(
      color: surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 7,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: _NewsImageBackground(
                    item: item,
                    colors: colors,
                    isDark: isDark,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: _NewsTitle(
                        item: item,
                        color: textColor,
                        maxLines: 2,
                      ),
                    ),
                  ),
                  _NewsSubtitle(item: item, color: textColor),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewsImageBackground extends StatelessWidget {
  const _NewsImageBackground({
    required this.item,
    required this.colors,
    required this.isDark,
  });

  final StudentHomeNews item;
  final List<Color> colors;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final skeletonColors = isDark
        ? [
            Color.alphaBlend(
              colors.first.withValues(alpha: 0.55),
              const Color(0xFF1F2937),
            ),
            Color.alphaBlend(
              colors.last.withValues(alpha: 0.45),
              const Color(0xFF111827),
            ),
          ]
        : colors;

    return NewsImageFrame(
      bytes: item.imageBytes,
      colors: skeletonColors,
      alignment: item.imageFocus,
      isLoading: item.usesImage && !item.hasImage,
      fit: BoxFit.cover,
    );
  }
}

class _NewsTitle extends StatelessWidget {
  const _NewsTitle({
    required this.item,
    required this.color,
    this.maxLines = 2,
  });

  final StudentHomeNews item;
  final Color color;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Text(
      item.title,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w900,
        fontSize: 14.5,
        height: 1.08,
      ),
    );
  }
}

class _NewsSubtitle extends StatelessWidget {
  const _NewsSubtitle({
    required this.item,
    required this.color,
    this.strong = false,
  });

  final StudentHomeNews item;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Text(
      item.subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color.withValues(alpha: strong ? 0.88 : 0.58),
        fontWeight: FontWeight.w600,
        fontSize: 10.5,
        height: 1.12,
      ),
    );
  }
}
