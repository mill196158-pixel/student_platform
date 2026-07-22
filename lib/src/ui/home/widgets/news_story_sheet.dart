import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';

class NewsStorySheet extends StatefulWidget {
  final List<HomeNewsItem> news;
  final int initialIndex;

  const NewsStorySheet({
    super.key,
    required this.news,
    required this.initialIndex,
  });

  @override
  State<NewsStorySheet> createState() => _NewsStorySheetState();
}

class _NewsStorySheetState extends State<NewsStorySheet> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.news.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FractionallySizedBox(
      heightFactor: 0.88,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Что нового',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Dots(count: widget.news.length, index: _index),
              const SizedBox(height: 16),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: widget.news.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) {
                    return _NewsStoryPage(item: widget.news[index]);
                  },
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Отлично'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewsStoryPage extends StatelessWidget {
  final HomeNewsItem item;

  const _NewsStoryPage({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = item.gradientColors.length >= 2
        ? item.gradientColors
        : const [Color(0xFFEDE7F6), Color(0xFFD9CCF5)];
    final textColor =
        ThemeData.estimateBrightnessForColor(colors.first) == Brightness.dark
            ? Colors.white
            : const Color(0xFF111827);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 240,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  right: -24,
                  bottom: -24,
                  child: Icon(
                    item.icon,
                    size: 180,
                    color: textColor.withValues(alpha: 0.16),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: textColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(item.icon, color: textColor, size: 30),
                      ),
                      const Spacer(),
                      Text(
                        item.title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor.withValues(alpha: 0.84),
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            item.body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            DateFormat('d MMMM yyyy', 'ru_RU').format(item.createdAt),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.52),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;

  const _Dots({
    required this.count,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 18 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}
