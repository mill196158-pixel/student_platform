import 'package:flutter/material.dart';

/// Returns true only when the sender explicitly accepts a smaller copy.
Future<bool?> choosePhotoSendMode(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Как отправить изображение?')),
        ListTile(
          leading: const Icon(Icons.photo_outlined),
          title: const Text('Фото — уменьшить'),
          subtitle: const Text(
              'При сжатии уменьшатся размер и детализация; ориентация сохранится, остальные EXIF-данные, включая геоданные, будут удалены. Если сжать нельзя, уйдёт оригинал. Файл на устройстве не изменится.'),
          onTap: () => Navigator.pop(context, true),
        ),
        ListTile(
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: const Text('Оригинал без изменений'),
          subtitle: const Text('Для QR-кодов, схем и документов.'),
          onTap: () => Navigator.pop(context, false),
        ),
      ]),
    ),
  );
}
