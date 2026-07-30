import 'package:flutter/material.dart';

import 'content_color_utils.dart';

/// Visual card layout variants for content surfaces.
enum ContentCardVariant {
  gradientText('gradient_text', 'Градиент + текст'),
  imageFull('image_full', 'Изображение на всю карточку'),
  imageOverlay('image_overlay', 'Изображение с наложением'),
  imageTopText('image_top_text', 'Изображение сверху'),
  compactIcon('compact_icon', 'Компактная с иконкой'),
  accentInfo('accent_info', 'Акцент / информация'),
  noImage('no_image', 'Без изображения');

  const ContentCardVariant(this.key, this.labelRu);

  final String key;
  final String labelRu;

  static ContentCardVariant? fromKey(String? raw) {
    if (raw == null) return null;
    for (final variant in values) {
      if (variant.key == raw) return variant;
    }
    return null;
  }
}

/// Picker with tiny visual tiles for card variants.
class ContentCardVariantPicker extends StatelessWidget {
  const ContentCardVariantPicker({
    required this.selected,
    required this.onChanged,
    this.allowed = ContentCardVariant.values,
    this.enabled = true,
    super.key,
  });

  final ContentCardVariant selected;
  final ValueChanged<ContentCardVariant> onChanged;
  final Iterable<ContentCardVariant> allowed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final allowedList = allowed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Вариант карточки', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final variant in allowedList)
              _VariantTile(
                variant: variant,
                selected: variant == selected,
                enabled: enabled,
                onTap: () => onChanged(variant),
              ),
          ],
        ),
      ],
    );
  }
}

class _VariantTile extends StatelessWidget {
  const _VariantTile({
    required this.variant,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ContentCardVariant variant;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 108,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : const Color(0xFFD8DCE8),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            _VariantPreview(variant: variant),
            const SizedBox(height: 6),
            Text(
              variant.labelRu,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _VariantPreview extends StatelessWidget {
  const _VariantPreview({required this.variant});

  final ContentCardVariant variant;

  @override
  Widget build(BuildContext context) {
    final gradient = contentLinearGradientFromHex(
      colorA: '#FFFBFF',
      colorB: '#F3EEF9',
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 52,
        width: double.infinity,
        child: switch (variant) {
          ContentCardVariant.gradientText => DecoratedBox(
            decoration: BoxDecoration(gradient: gradient),
            child: const Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.all(6),
                child: Text('Aa', style: TextStyle(fontSize: 10)),
              ),
            ),
          ),
          ContentCardVariant.imageFull => Stack(
            fit: StackFit.expand,
            children: [
              Container(color: const Color(0xFFDCD0FA)),
              const Center(child: Icon(Icons.image_outlined, size: 16)),
            ],
          ),
          ContentCardVariant.imageOverlay => Stack(
            fit: StackFit.expand,
            children: [
              Container(color: const Color(0xFFC9B8F3)),
              Container(
                color: Colors.black26,
                alignment: Alignment.bottomLeft,
                padding: const EdgeInsets.all(4),
                child: const Text('Aa', style: TextStyle(fontSize: 8)),
              ),
            ],
          ),
          ContentCardVariant.imageTopText => Column(
            children: [
              Expanded(child: Container(color: const Color(0xFFE8E0F5))),
              Container(
                height: 14,
                color: Colors.white,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: const Text('…', style: TextStyle(fontSize: 8)),
              ),
            ],
          ),
          ContentCardVariant.compactIcon => Row(
            children: [
              Container(
                width: 22,
                height: double.infinity,
                color: const Color(0xFF7C63D8).withValues(alpha: 0.2),
                child: const Icon(Icons.star_outline, size: 12),
              ),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Text('…', style: TextStyle(fontSize: 8)),
                ),
              ),
            ],
          ),
          ContentCardVariant.accentInfo => Container(
            color: const Color(0xFFE8F1FF),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.all(6),
            child: const Icon(Icons.info_outline, size: 14),
          ),
          ContentCardVariant.noImage => Container(
            color: const Color(0xFFF4F5FA),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.all(6),
            child: const Text('Текст', style: TextStyle(fontSize: 9)),
          ),
        },
      ),
    );
  }
}
