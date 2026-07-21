import 'dart:typed_data';

import 'package:flutter/material.dart';

class NewsImageField extends StatelessWidget {
  const NewsImageField({
    required this.imageBytes,
    required this.onPick,
    required this.onClear,
    this.errorText,
    super.key,
  });

  final Uint8List? imageBytes;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final String? errorText;

  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;

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
            onTap: onPick,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFD7D9E4)),
              ),
              child: Row(
                children: [
                  _Thumbnail(bytes: imageBytes),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasImage
                              ? 'Изображение выбрано'
                              : 'Выберите изображение',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          hasImage
                              ? 'JPG, PNG или WebP · до 5 МБ'
                              : 'Как аватарка: выберите файл с компьютера',
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
              onPressed: onPick,
              icon: Icon(hasImage ? Icons.sync_rounded : Icons.upload_rounded),
              label: Text(hasImage ? 'Заменить' : 'Выбрать изображение'),
            ),
            if (hasImage)
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Удалить'),
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
  const _Thumbnail({required this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFFE9EAF1),
        border: Border.all(color: const Color(0xFFD7D9E4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null || bytes!.isEmpty
          ? const Icon(Icons.image_outlined, color: Color(0xFF8B8FA3))
          : Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}
