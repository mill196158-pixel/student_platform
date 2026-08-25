import 'content_icon_resolver.dart';
import 'content_models.dart';

/// True when the card should fetch hero bytes from [ProfileFeedPayload.imageAssetId].
bool profileFeedCardNeedsImageFetch(ManagedProfileFeedCard card) {
  final usesImage = contentCardVariantUsesImage(
    effectiveContentCardVariant(card.payload.cardVariant),
  );
  if (!usesImage) return false;
  if (card.imageBytes != null && card.imageBytes!.isNotEmpty) return false;
  final id = card.payload.imageAssetId?.trim();
  return id != null && id.isNotEmpty;
}

/// Mark image variants that still need a download as loading.
List<ManagedProfileFeedCard> profileFeedCardsWithImageLoading(
  List<ManagedProfileFeedCard> cards,
) {
  return [
    for (final card in cards)
      if (profileFeedCardNeedsImageFetch(card))
        card.copyWith(imageLoading: true)
      else
        card,
  ];
}
