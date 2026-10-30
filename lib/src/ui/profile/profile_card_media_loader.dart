import 'dart:typed_data';
import 'package:student_ui/student_ui.dart';

/// Each asset starts immediately; a slow icon never holds back the main image.
Future<void> hydrateProfileCardMedia(
  ManagedProfileFeedCard card, {
  required Future<Uint8List?> Function(String id, String version) fetch,
  required void Function(ManagedProfileFeedCard) onUpdate,
}) async {
  final version = '${card.id}|${card.sortOrder}';
  var current = card;
  Future<void> image() async {
    final id = card.payload.imageAssetId?.trim();
    if (!profileFeedCardNeedsImageFetch(card) || id == null || id.isEmpty)
      return;
    Uint8List? bytes;
    try {
      bytes = await fetch(id, version);
    } catch (_) {}
    current = current.copyWith(
        imageBytes: bytes,
        imageLoading: false,
        clearImageBytes: bytes == null || bytes.isEmpty);
    onUpdate(current);
  }

  Future<void> icon() async {
    final id = card.payload.iconAssetId?.trim();
    if ((card.iconBytes?.isNotEmpty ?? false) || id == null || id.isEmpty)
      return;
    Uint8List? bytes;
    try {
      bytes = await fetch(id, '$version|icon');
    } catch (_) {}
    current = current.copyWith(iconBytes: bytes);
    onUpdate(current);
  }

  await Future.wait([image(), icon()]);
  current = current.copyWith(imageLoading: false);
  onUpdate(current);
}
