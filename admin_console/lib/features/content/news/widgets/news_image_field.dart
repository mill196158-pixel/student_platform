import 'dart:typed_data';

import 'package:flutter/material.dart';

enum NewsImageFieldStatus { empty, loading, localPreview, saved, error }

class NewsImageField extends StatelessWidget {
  const NewsImageField({
    required this.imageBytes,
    required this.status,
    required this.onPick,
    required this.onClear,
    this.onRetry,
    this.errorText,
    this.statusText,
    super.key,
  });

  final Uint8List? imageBytes;
  final NewsImageFieldStatus status;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final VoidCallback? onRetry;
  final String? errorText;
  final String? statusText;

  bool get hasVisual =>
      (imageBytes != null && imageBytes!.isNotEmpty) ||
      status == NewsImageFieldStatus.saved ||
      status == NewsImageFieldStatus.localPreview ||
      status == NewsImageFieldStatus.loading ||
      status == NewsImageFieldStatus.error;

  String get _title => switch (status) {
    NewsImageFieldStatus.loading => 'Загружаем изображение…',
    NewsImageFieldStatus.localPreview => 'Изображение выбрано (не сохранено)',
    NewsImageFieldStatus.saved => 'Изображение сохранено',
    NewsImageFieldStatus.error => 'Не удалось загрузить',
    NewsImageFieldStatus.empty => 'Выберите изображение',
  };

  String get _subtitle =>
      statusText ??
      switch (status) {
        NewsImageFieldStatus.loading =>
          'Получаем файл из защищённого хранилища',
        NewsImageFieldStatus.localPreview =>
          'Сохраните черновик, чтобы загрузить файл на сервер',
        NewsImageFieldStatus.saved => 'JPG, PNG или WebP · до 5 МБ',
        NewsImageFieldStatus.error => 'Проверьте сеть и попробуйте ещё раз',
        NewsImageFieldStatus.empty =>
          'Как аватарка: выберите файл с компьютера',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Изображение',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Material(
          color: const Color(0xFFF7F7FB),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: status == NewsImageFieldStatus.loading ? null : onPick,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFD7D9E4)),
              ),
              child: Row(
                children: [
                  // Fixed 64×64 thumb — card width/height stay stable as bytes arrive.
                  _Thumbnail(
                    bytes: imageBytes,
                    loading: status == NewsImageFieldStatus.loading,
                    error: status == NewsImageFieldStatus.error,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF6E7180),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: status == NewsImageFieldStatus.loading ? null : onPick,
              icon: Icon(hasVisual ? Icons.sync_rounded : Icons.upload_rounded),
              label: Text(hasVisual ? 'Заменить' : 'Выбрать изображение'),
            ),
            if (hasVisual && status != NewsImageFieldStatus.loading)
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Удалить'),
              ),
            if (status == NewsImageFieldStatus.error && onRetry != null)
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Повторить'),
              ),
          ],
        ),
        if (errorText != null) ...[
          const SizedBox(height: 8),
          Text(
            errorText!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.bytes,
    this.loading = false,
    this.error = false,
  });

  final Uint8List? bytes;
  final bool loading;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final hasBytes = bytes != null && bytes!.isNotEmpty;
    return SizedBox(
      width: 64,
      height: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: const Color(0xFFE9EAF1),
          border: Border.all(color: const Color(0xFFD7D9E4)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFFE9EAF1)),
              if (loading && !hasBytes)
                const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (error && !hasBytes)
                const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Color(0xFF8B8FA3),
                  ),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: hasBytes
                    ? Image.memory(
                        bytes!,
                        key: ValueKey<int>(bytes!.length),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : !loading && !error
                    ? const Icon(
                        Icons.image_outlined,
                        key: ValueKey('placeholder'),
                        color: Color(0xFF8B8FA3),
                      )
                    : const SizedBox.shrink(key: ValueKey('wait')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
