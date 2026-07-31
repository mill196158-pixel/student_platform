import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Explicit render contract for hero/cover/logo/background image planes.
///
/// Variant identity always comes from payload `cardVariant`. Image_* variants
/// must never silently fall back to `gradient_text`.
@immutable
sealed class ContentImageRenderState {
  const ContentImageRenderState();

  /// Non-image variant — plane not used.
  static const notApplicable = ContentImageNotApplicable();

  /// Download / decode in progress.
  static const loading = ContentImageLoading();

  /// Image variant selected but no asset bytes available.
  static const missing = ContentImageMissing();

  bool get isReady => this is ContentImageReady;
  bool get isLoading => this is ContentImageLoading;
  bool get isMissing => this is ContentImageMissing;
  bool get isFailed => this is ContentImageFailed;
  bool get isNotApplicable => this is ContentImageNotApplicable;

  Uint8List? get bytesOrNull => switch (this) {
        final ContentImageReady ready => ready.bytes,
        _ => null,
      };

  /// Backward-compatible mapping from legacy bytes + loading flags.
  static ContentImageRenderState fromLegacy({
    required bool usesImageVariant,
    Uint8List? bytes,
    bool loading = false,
    bool failed = false,
    VoidCallback? onRetry,
  }) {
    if (!usesImageVariant) return notApplicable;
    if (failed) return ContentImageFailed(onRetry: onRetry);
    if (loading) return ContentImageRenderState.loading;
    if (bytes != null && bytes.isNotEmpty) {
      return ContentImageReady(bytes);
    }
    return missing;
  }
}

final class ContentImageNotApplicable extends ContentImageRenderState {
  const ContentImageNotApplicable();
}

final class ContentImageLoading extends ContentImageRenderState {
  const ContentImageLoading();
}

final class ContentImageReady extends ContentImageRenderState {
  const ContentImageReady(this.bytes);

  final Uint8List bytes;
}

final class ContentImageMissing extends ContentImageRenderState {
  const ContentImageMissing();
}

final class ContentImageFailed extends ContentImageRenderState {
  const ContentImageFailed({this.onRetry});

  final VoidCallback? onRetry;
}
