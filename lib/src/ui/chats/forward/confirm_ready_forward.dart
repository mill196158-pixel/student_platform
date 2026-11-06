import 'package:flutter/material.dart';
import '../core/forward_payload.dart';

List<Widget> _reviewItems(ForwardPayload payload, [int depth = 0]) => [
      if ((payload.caption ?? '').trim().isNotEmpty)
        Text('Подпись: ${payload.caption!.trim()}'),
      for (final item in payload.items) ...[
        const SizedBox(height: 12),
        Text(item.authorName.trim().isEmpty ? 'Сообщение' : item.authorName.trim(),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        if (depth < 8 && ForwardPayload.isForwardText(item.text) &&
            ForwardPayload.tryParse(item.text) != null)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _reviewItems(ForwardPayload.tryParse(item.text)!, depth + 1),
            ),
          )
        else if (ForwardPayload.displayText(item.text).isNotEmpty)
          Text(ForwardPayload.displayText(item.text)),
        for (final file in item.files)
          Text('Вложение: ${file.name.trim().isEmpty ? 'без названия' : file.name.trim()}'),
      ],
    ];

/// A durable ready record can outlive its source session. Reopening it must
/// not silently turn it back into a sendable composer item.
Future<bool> confirmReadyForward(BuildContext context, ForwardPayload payload,
        {String actionLabel = 'Продолжить'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Проверить пересылку'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _reviewItems(payload),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Позже'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(actionLabel),
          ),
        ],
      ),
    ) ==
    true;
