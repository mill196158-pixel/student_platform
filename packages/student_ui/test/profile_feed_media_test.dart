import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  ManagedProfileFeedCard card({
    String variant = 'image_overlay',
    String? imageAssetId = 'asset-1',
    Uint8List? imageBytes,
    bool imageLoading = false,
  }) {
    return ManagedProfileFeedCard(
      id: 'pf-1',
      origin: ContentOrigin.admin,
      sortOrder: 0,
      priority: 0,
      payload: ProfileFeedPayload(
        title: 'T',
        subtitle: 'S',
        ctaLabel: 'C',
        imageAssetId: imageAssetId,
        cardVariant: variant,
      ),
      imageBytes: imageBytes,
      imageLoading: imageLoading,
    );
  }

  test('needs fetch for image variant with asset id and no bytes', () {
    expect(profileFeedCardNeedsImageFetch(card()), isTrue);
  });

  test('no fetch for gradient_text even with asset id', () {
    expect(
      profileFeedCardNeedsImageFetch(card(variant: 'gradient_text')),
      isFalse,
    );
  });

  test('no fetch when bytes already present', () {
    expect(
      profileFeedCardNeedsImageFetch(
        card(imageBytes: Uint8List.fromList([1])),
      ),
      isFalse,
    );
  });

  test('loading helper marks pending image variants', () {
    final next = profileFeedCardsWithImageLoading([
      card(),
      card(variant: 'gradient_text', imageAssetId: 'x'),
      card(imageBytes: Uint8List.fromList([1])),
    ]);
    expect(next[0].imageLoading, isTrue);
    expect(next[1].imageLoading, isFalse);
    expect(next[2].imageLoading, isFalse);
  });
}
