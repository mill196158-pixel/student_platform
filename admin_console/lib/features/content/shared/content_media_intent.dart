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
    this.localMimeType,
    this.assetId,
    this.error,
  });

  final ContentMediaPhase phase;
  final Uint8List? localBytes;
  final String? localMimeType;
  final String? assetId;
  final String? error;

  static const untouched = ContentMediaIntentState();

  /// Bytes to show in phone preview (local pick wins over resolved asset).
  Uint8List? get bytesForPreview {
    if (phase == ContentMediaPhase.removed) return null;
    if (localBytes != null && localBytes!.isNotEmpty) return localBytes;
    return null;
  }

  /// Local pick wins; removed clears; otherwise use [resolvedBytes] cache.
  Uint8List? previewBytes({Uint8List? resolvedBytes}) {
    final local = bytesForPreview;
    if (local != null) return local;
    if (shouldOmitAssetOnSave) return null;
    return resolvedBytes;
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

  ContentMediaIntentState pickLocal(Uint8List bytes, {String? mimeType}) {
    return ContentMediaIntentState(
      phase: ContentMediaPhase.pendingLocal,
      localBytes: bytes,
      localMimeType: mimeType,
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
    String? localMimeType,
    String? assetId,
    String? error,
    bool clearLocalBytes = false,
    bool clearAssetId = false,
    bool clearError = false,
  }) {
    return ContentMediaIntentState(
      phase: phase ?? this.phase,
      localBytes: clearLocalBytes ? null : (localBytes ?? this.localBytes),
      localMimeType: clearLocalBytes
          ? null
          : (localMimeType ?? this.localMimeType),
      assetId: clearAssetId ? null : (assetId ?? this.assetId),
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ContentMediaIntentState &&
        other.phase == phase &&
        _bytesEq(other.localBytes, localBytes) &&
        other.localMimeType == localMimeType &&
        other.assetId == assetId &&
        other.error == error;
  }

  @override
  int get hashCode =>
      Object.hash(phase, assetId, error, localBytes?.length, localMimeType);
}

/// Determine the actual upload type from the file header, not its extension.
String imageUploadMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      _bytesEq(
        bytes.sublist(0, 8),
        Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      )) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  throw StateError('Выберите изображение в формате JPG, PNG или WebP.');
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
