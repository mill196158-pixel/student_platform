import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'admin_image_picker.dart';

/// The Windows web editor asks before lossy photo compression. Injected test
/// pickers and the existing non-Windows paths retain their current behavior.
Future<PickedAdminImage?> pickAdminImageForEditor(
  BuildContext context,
  AdminImagePicker picker, {
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return null;
  if (!kIsWeb ||
      defaultTargetPlatform != TargetPlatform.windows ||
      picker is! LocalAdminImagePicker)
    return picker.pickImage();
  final photo = await showAdminPhotoMode(context);
  if (photo == null || !isCurrent()) return null;
  return LocalAdminImagePicker(
    photoMode: photo,
    isCurrent: isCurrent,
  ).pickImage();
}

Future<bool?> showAdminPhotoMode(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Как загрузить изображение?'),
      content: const Text(
        'Подходящее фото уменьшится с потерей детализации и EXIF-данных, включая геоданные. Если сжать его нельзя, используется оригинал до 5 МБ. Файл на компьютере не изменится. Для QR-кодов, схем и документов выберите оригинал.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Оригинал'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Сжать фото'),
        ),
      ],
    ),
  );
