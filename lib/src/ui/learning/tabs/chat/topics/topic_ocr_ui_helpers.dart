import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'topic_list_models.dart';

/// Dialog to pick PDF pages for OCR (1-based labels, 0-based indices).
Future<List<int>?> showTopicPdfPagePicker({
  required BuildContext context,
  required int pageCount,
  int maxPages = topicListMaxOcrPages,
}) async {
  if (pageCount <= 0) return null;

  final initial = List.generate(
    pageCount.clamp(0, maxPages),
    (index) => index,
  );

  return showDialog<List<int>>(
    context: context,
    builder: (ctx) {
      final selected = Set<int>.from(initial);
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final media = MediaQuery.of(context);
          return Dialog(
            insetPadding: const EdgeInsets.all(16),
            constraints: const BoxConstraints(maxWidth: 560),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight:
                  (media.size.height - media.viewInsets.bottom - 32).clamp(0.0, 720.0)),
              child: Padding(padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: Text('Страницы для OCR',
                        style: Theme.of(context).textTheme.titleMedium)),
                    IconButton(tooltip: 'Закрыть', icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx)),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(child: ListView(children: [
                    Text('Выбрано ${selected.length} из $maxPages страниц для распознавания.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    for (var index = 0; index < pageCount; index++)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Страница ${index + 1}'),
                        value: selected.contains(index),
                        onChanged: !selected.contains(index) && selected.length >= maxPages ? null : (value) {
                          setDialogState(() {
                            if (value == true) {
                              if (selected.length >= maxPages) return;
                              selected.add(index);
                            } else {
                              selected.remove(index);
                            }
                          });
                        },
                      ),
                  ])),
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: Wrap(spacing: 8, runSpacing: 8, children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                    FilledButton(onPressed: selected.isEmpty ? null
                        : () => Navigator.pop(ctx, selected.toList()..sort()),
                        child: const Text('Распознать')),
                  ])),
                ]),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Simple rotate/crop actions before OCR.
Future<Uint8List?> showTopicImagePreprocessSheet({
  required BuildContext context,
  required Uint8List bytes,
  required Future<Uint8List> Function(Uint8List current, int degrees) onRotate,
  required Future<Uint8List?> Function(Uint8List current) onCrop,
}) async {
  var working = bytes;

  return showModalBottomSheet<Uint8List>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Подготовка изображения',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Поверните или обрежьте фото перед распознаванием.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          working = await onRotate(working, 90);
                          if (!context.mounted) return;
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.rotate_right_outlined),
                        label: const Text('Повернуть 90°'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final cropped = await onCrop(working);
                          if (!context.mounted) return;
                          if (cropped != null) {
                            working = cropped;
                            setSheetState(() {});
                          }
                        },
                        icon: const Icon(Icons.crop_outlined),
                        label: const Text('Обрезать'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, working),
                    child: const Text('Продолжить OCR'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена'),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
