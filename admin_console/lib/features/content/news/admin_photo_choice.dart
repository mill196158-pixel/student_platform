import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_image_picker.dart';

/// Optimise after selection, then let the editor inspect lossy JPEGs before
/// any editor mutation or upload. Injected pickers keep their own behaviour.
Future<PickedAdminImage?> pickAdminImageForEditor(
  BuildContext context,
  AdminImagePicker picker, {
  required bool Function() isCurrent,
  Listenable? invalidation,
  Stream<AuthState>? authEvents,
}) async {
  if (!isCurrent()) return null;
  final picked = picker is LocalAdminImagePicker
      ? await LocalAdminImagePicker(
          photoMode: true, automatic: true, isCurrent: isCurrent).pickImage()
      : await picker.pickImage();
  if (picked == null || !isCurrent() || !context.mounted) return null;
  return reviewAdminImage(context, picked, isCurrent: isCurrent,
      invalidation: invalidation, authEvents: authEvents);
}

Future<PickedAdminImage?> reviewAdminImage(
  BuildContext context,
  PickedAdminImage picked, {
  required bool Function() isCurrent,
  Listenable? invalidation,
  Stream<AuthState>? authEvents,
}) async {
  if (!isCurrent() || !context.mounted) return null;
  final original = picked.originalBytes;
  if (original == null) {
    final message = picked.optimizationMessage;
    if (message != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
    }
    return picked;
  }
  final canUseOriginal = original.length <= LocalAdminImagePicker.maxBytes;
  final navigator = Navigator.of(context, rootNavigator: true);
  final active = ValueNotifier<bool>(true);
  DialogRoute<bool>? route;
  bool current() {
    try { return context.mounted && isCurrent(); } catch (_) { return false; }
  }
  void invalidate() {
    if (!active.value) return;
    active.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = route;
      if (target != null && target.isActive && navigator.mounted) {
        navigator.removeRoute(target);
      }
    });
  }
  void check() { if (!current()) invalidate(); }
  invalidation?.addListener(check);
  final authSubscription = authEvents?.listen((event) {
    if (event.event == AuthChangeEvent.initialSession) {
      check();
    } else {
      // Do not depend on SDK event delivery ordering relative to currentSession.
      invalidate();
    }
  },
      onError: (Object _, StackTrace __) => invalidate());
  final targetRoute = DialogRoute<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Изображение уменьшено'),
      content: ListenableBuilder(listenable: active, builder: (_, __) =>
        active.value && current() ? SizedBox(
        width: 720,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('JPEG: ${(original.length / 1024).ceil()} → ${(picked.bytes.length / 1024).ceil()} КБ. '
              'Качество и детализация снижены, EXIF и геоданные удалены. '
              'Проверьте мелкий текст и QR-коды; их читаемость не гарантируется. '
              'Увеличивайте изображение прокруткой или жестом.'),
          if (!canUseOriginal)
            const Text('Оригинал больше 5 МБ и не может быть загружен. Для оригинала выберите файл меньшего размера.'),
          const SizedBox(height: 12),
          SizedBox(height: 240, child: Row(children: [
            Expanded(child: _Preview(label: 'Оригинал', bytes: original)),
            const SizedBox(width: 12),
            Expanded(child: _Preview(label: 'Уменьшенное', bytes: picked.bytes)),
          ])),
        ])),
      ) : const SizedBox.shrink()),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Отмена')),
        TextButton(onPressed: canUseOriginal ? () => Navigator.pop(dialogContext, false) : null,
            child: const Text('Оставить оригинал')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Использовать уменьшенное')),
      ],
    ),
  );
  route = targetRoute;
  bool? useCompressed;
  try {
    final pending = navigator.push(targetRoute);
    check();
    useCompressed = await pending;
  } finally {
    invalidation?.removeListener(check);
    final cancelled = authSubscription?.cancel();
    if (cancelled != null) unawaited(cancelled.catchError((Object _) {}));
    active.dispose();
  }
  if (useCompressed == null || !isCurrent() || !context.mounted) return null;
  if (useCompressed) {
    return PickedAdminImage(bytes: picked.bytes, fileName: picked.fileName,
        mimeType: picked.mimeType);
  }
  if (!canUseOriginal) return null;
  return PickedAdminImage(bytes: Uint8List.fromList(original),
      fileName: picked.fileName, mimeType: picked.mimeType);
}

class _Preview extends StatelessWidget {
  const _Preview({required this.label, required this.bytes});
  final String label;
  final Uint8List bytes;
  @override
  Widget build(BuildContext context) => Column(children: [
    Text(label),
    Expanded(child: ClipRect(child: InteractiveViewer(
      minScale: 1, maxScale: 4, trackpadScrollCausesScale: true,
      child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
    ))),
  ]);
}
