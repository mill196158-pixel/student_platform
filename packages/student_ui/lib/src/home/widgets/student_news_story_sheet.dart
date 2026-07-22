import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../home_preview_models.dart';
import 'news_image_frame.dart';

/// Full-screen story reader for published news.
///
/// Mirrors the compact card visual language ([StudentHomeNewsCard]) but at a
/// large hero size, and shows the full body text and publication date.
class StudentNewsStorySheet extends StatefulWidget {
  const StudentNewsStorySheet({
    required this.news,
    this.initialIndex = 0,
    this.onClosed,
    this.onPageChanged,
    this.resolveImage,
    super.key,
  });

  final List<StudentHomeNews> news;
  final int initialIndex;

  /// Called with the [StudentHomeNews.id] currently shown when the sheet is
  /// dismissed (close button, «Отлично», or swipe-down).
  final ValueChanged<String>? onClosed;

  /// Called with the [StudentHomeNews.id] of each page as it becomes visible.
  final ValueChanged<String>? onPageChanged;

  /// Optional resolver used to ensure current + next story images are ready
  /// before the user swipes.
  final Future<Uint8List?> Function(StudentHomeNews item)? resolveImage;

  @override
  State<StudentNewsStorySheet> createState() => _StudentNewsStorySheetState();
}

class _StudentNewsStorySheetState extends State<StudentNewsStorySheet> {
  late final PageController _controller;
  late int _index;
  late List<StudentHomeNews> _news;

  @override
  void initState() {
    super.initState();
    _news = List<StudentHomeNews>.from(widget.news);
    _index = _news.isEmpty ? 0 : widget.initialIndex.clamp(0, _news.length - 1);
    _controller = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheAround(_index);
    });
  }

  @override
  void didUpdateWidget(covariant StudentNewsStorySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.news != widget.news) {
      _news = List<StudentHomeNews>.from(widget.news);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _precacheAround(int index) async {
    await _ensureImage(index);
    if (index + 1 < _news.length) {
      await _ensureImage(index + 1);
    }
  }

  Future<void> _ensureImage(int index) async {
    if (index < 0 || index >= _news.length) return;
    final item = _news[index];
    if (!item.usesImage) return;
    Uint8List? bytes = item.imageBytes;
    if ((bytes == null || bytes.isEmpty) && widget.resolveImage != null) {
      bytes = await widget.resolveImage!(item);
      if (!mounted || bytes == null || bytes.isEmpty) return;
      setState(() {
        _news[index] = item.copyWith(imageBytes: bytes);
      });
    }
    if (!mounted || bytes == null || bytes.isEmpty) return;
    await precacheImage(
      MemoryImage(bytes),
      context,
      onError: (_, __) {},
    );
  }

  void _close() {
    if (_news.isNotEmpty) {
      widget.onClosed?.call(_news[_index].id);
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_news.isEmpty) {
      return const SizedBox.shrink();
    }

    return FractionallySizedBox(
      heightFactor: 0.9,
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
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Dots(count: _news.length, index: _index),
              const SizedBox(height: 16),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _news.length,
                  onPageChanged: (value) {
                    setState(() => _index = value);
                    widget.onPageChanged?.call(_news[value].id);
                    _precacheAround(value);
                  },
                  itemBuilder: (context, index) {
                    return _NewsStoryPage(item: _news[index]);
                  },
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _close,
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
  const _NewsStoryPage({required this.item});

  final StudentHomeNews item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = item.publishedAt;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StoryHero(item: item),
          const SizedBox(height: 22),
          if (item.variant == StudentHomeNewsVariant.imageOnly) ...[
            Text(
              item.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.05,
              ),
            ),
            if (item.subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                item.subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ],
            const SizedBox(height: 14),
          ],
          Text(
            item.body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (date != null) ...[
            const SizedBox(height: 18),
            Text(
              _formatDate(date),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.52),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime value) {
    const months = <String>[
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

/// Large variant-aware hero that reuses the card's visual language.
class _StoryHero extends StatelessWidget {
  const _StoryHero({required this.item});

  final StudentHomeNews item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = item.gradientColors.length >= 2
        ? item.gradientColors
        : const [Color(0xFFEDE7F6), Color(0xFFD9CCF5)];
    final onGradient =
        ThemeData.estimateBrightnessForColor(colors.first) == Brightness.dark
            ? Colors.white
            : const Color(0xFF111827);

    final usesPhoto = item.usesImage;
    final showOverlay =
        usesPhoto && item.variant == StudentHomeNewsVariant.imageOverlay;

    // gradientText → decorative icon + text
    // imageOnly → full-bleed image, no overlays
    // imageOverlay → image + text only (no auto icon)
    // imageWithText → image hero; title/body below sheet (no icon on image)
    // ClipRRect on the outer container only — no inner padding/stripes.
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: SizedBox(
        height: 280,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (usesPhoto)
              Positioned.fill(
                child: NewsImageFrame(
                  bytes: item.imageBytes,
                  colors: colors,
                  alignment: item.imageFocus,
                  isLoading: !item.hasImage,
                  fit: BoxFit.cover,
                ),
              )
            else
              Positioned.fill(child: _GradientBackground(colors: colors)),
            if (showOverlay)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.10),
                        Colors.black.withValues(
                          alpha: item.overlayDarken.clamp(0.25, 0.85),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!usesPhoto) ...[
              Positioned(
                right: -24,
                bottom: -24,
                child: Icon(
                  item.icon,
                  size: 180,
                  color: onGradient.withValues(alpha: 0.16),
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
                        color: onGradient.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(item.icon, color: onGradient, size: 30),
                    ),
                    const Spacer(),
                    Text(
                      item.title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: onGradient,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    if (item.subtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        item.subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: onGradient.withValues(alpha: 0.84),
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (showOverlay)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Text(
                      item.title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    if (item.subtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        item.subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.84),
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GradientBackground extends StatelessWidget {
  const _GradientBackground({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

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
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}
