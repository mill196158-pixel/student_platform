import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Lifecycle phase for a single media field in Admin editors.
enum ContentMediaPhase {
  untouched,
  pendingLocal,
  uploading,
  uploaded,
  removed,
  failed,
}

/// Typed media intent separate from asset download / resolver loading.
@immutable
class ContentMediaIntentState {
  const ContentMediaIntentState({
    this.phase = ContentMediaPhase.untouched,
    this.localBytes,
    this.assetId,
    this.error,
  });

  final ContentMediaPhase phase;
  final Uint8List? localBytes;
  final String? assetId;
  final String? error;

  static const untouched = ContentMediaIntentState();

  /// Bytes to show in phone preview (local pick wins over resolved asset).
  Uint8List? get bytesForPreview {
    if (phase == ContentMediaPhase.removed) return null;
    if (localBytes != null && localBytes!.isNotEmpty) return localBytes;
    return null;
  }

  /// When true, persisted asset id must be omitted on save payload.
  bool get shouldOmitAssetOnSave => phase == ContentMediaPhase.removed;

  bool get hasLocalPick => phase == ContentMediaPhase.pendingLocal;

  ContentMediaIntentState clear({String? assetId}) {
    return ContentMediaIntentState(
      phase: ContentMediaPhase.untouched,
      assetId: assetId,
    );
  }

  ContentMediaIntentState pickLocal(Uint8List bytes) {
    return ContentMediaIntentState(
      phase: ContentMediaPhase.pendingLocal,
      localBytes: bytes,
      assetId: assetId,
    );
  }

  ContentMediaIntentState markUploading() {
    return copyWith(phase: ContentMediaPhase.uploading, error: null);
  }

  ContentMediaIntentState markUploaded(String uploadedAssetId) {
    return ContentMediaIntentState(
      phase: ContentMediaPhase.uploaded,
      assetId: uploadedAssetId,
    );
  }

  ContentMediaIntentState markFailed(String message) {
    return copyWith(phase: ContentMediaPhase.failed, error: message);
  }

  ContentMediaIntentState markRemoved() {
    return const ContentMediaIntentState(phase: ContentMediaPhase.removed);
  }

  ContentMediaIntentState copyWith({
    ContentMediaPhase? phase,
    Uint8List? localBytes,
    String? assetId,
    String? error,
    bool clearLocalBytes = false,
    bool clearAssetId = false,
    bool clearError = false,
  }) {
    return ContentMediaIntentState(
      phase: phase ?? this.phase,
      localBytes: clearLocalBytes ? null : (localBytes ?? this.localBytes),
      assetId: clearAssetId ? null : (assetId ?? this.assetId),
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ContentMediaIntentState &&
        other.phase == phase &&
        _bytesEq(other.localBytes, localBytes) &&
        other.assetId == assetId &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(phase, assetId, error, localBytes?.length);
}

bool _bytesEq(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
