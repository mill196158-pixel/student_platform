import 'package:flutter/material.dart';

/// A pending result is deliberately informational: reopening a chat must not
/// turn an ambiguous send or upload into a second network operation.
class DurableForwardPendingNotice extends StatelessWidget {
  const DurableForwardPendingNotice({super.key, required this.upload});

  final bool upload;

  @override
  Widget build(BuildContext context) => Text(upload
      ? 'Не удалось определить результат подготовки вложений. Пересылка сохранена; повторная загрузка автоматически не выполняется.'
      : 'Не удалось определить результат отправки. Пересылка сохранена; повторная отправка автоматически не выполняется.');
}
