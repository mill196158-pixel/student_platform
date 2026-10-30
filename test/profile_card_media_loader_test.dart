import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/profile/profile_card_media_loader.dart';

void main() {
  test('image and icon start together; slow icon cannot delay image paint',
      () async {
    final card = ManagedProfileFeedCard.tryParse({
      'id': 'card',
      'template_key': 'profile_feed_card_v1',
      'schema_version': 1,
      'placement': 'profile_feed',
      'sort_order': 0,
      'priority': 0,
      'origin': 'admin',
      'payload': {
        'title': 'Banner',
        'subtitle': 'Text',
        'cta_label': 'Open',
        'cta_route': '/schedule',
        'card_variant': 'image_full',
        'image_asset_id': 'image',
        'icon_asset_id': 'icon'
      }
    })!;
    final textCard = card.copyWith(
        id: 'text',
        payload: card.payload.copyWith(cardVariant: 'gradient_text'));
    final missingAsset =
        card.copyWith(payload: card.payload.copyWith(clearImageAssetId: true));
    expect(readyProfileFeedCards([card, missingAsset, textCard]), [textCard]);
    final image = Completer<Uint8List?>();
    final icon = Completer<Uint8List?>();
    final started = <String>[];
    final updates = <ManagedProfileFeedCard>[];
    final work = hydrateProfileCardMedia(card, fetch: (id, version) {
      started.add(id);
      return id == 'image' ? image.future : icon.future;
    }, onUpdate: updates.add);
    expect(started, containsAll(['image', 'icon']));
    image.complete(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);
    expect(updates.last.imageBytes, [1, 2, 3]);
    expect(readyProfileFeedCards([textCard, updates.last]),
        [textCard, updates.last]);
    expect(
        readyProfileFeedCards([updates.last.copyWith(clearImageBytes: true)]),
        isEmpty);
    expect(updates.last.imageLoading, isFalse);
    expect(icon.isCompleted, isFalse);
    icon.complete(Uint8List.fromList([4]));
    await work;
    expect(updates.last.imageBytes, [1, 2, 3]);
    expect(updates.last.iconBytes, [4]);
  });
}
