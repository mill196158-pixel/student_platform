import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/content_media_intent.dart';

void main() {
  group('ContentMediaIntentState', () {
    test(
      'image format comes from bytes, and MIME survives state transitions',
      () {
        final jpeg = Uint8List.fromList([255, 216, 255, 0]);
        final webp = Uint8List.fromList([
          82,
          73,
          70,
          70,
          0,
          0,
          0,
          0,
          87,
          69,
          66,
          80,
        ]);
        final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
        expect(imageUploadMime(jpeg), 'image/jpeg');
        expect(imageUploadMime(webp), 'image/webp');
        expect(imageUploadMime(png), 'image/png');
        expect(
          () => imageUploadMime(Uint8List.fromList([1, 2, 3])),
          throwsStateError,
        );
        final picked = ContentMediaIntentState.untouched.pickLocal(
          jpeg,
          mimeType: 'image/jpeg',
        );
        expect(
          picked.markUploading().markFailed('retry').localMimeType,
          'image/jpeg',
        );
        expect(picked.copyWith(clearLocalBytes: true).localMimeType, isNull);
        expect(picked.markUploaded('id').localMimeType, isNull);
        expect(picked, isNot(picked.copyWith(localMimeType: 'image/png')));
      },
    );
    test('pickLocal sets pendingLocal and bytesForPreview', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final state = ContentMediaIntentState.untouched.pickLocal(bytes);

      expect(state.phase, ContentMediaPhase.pendingLocal);
      expect(state.bytesForPreview, bytes);
      expect(state.shouldOmitAssetOnSave, isFalse);
    });

    test('markRemoved omits asset on save and preview bytes', () {
      final removed = ContentMediaIntentState(
        assetId: 'asset-1',
        localBytes: Uint8List.fromList([9]),
      ).markRemoved();

      expect(removed.phase, ContentMediaPhase.removed);
      expect(removed.bytesForPreview, isNull);
      expect(removed.shouldOmitAssetOnSave, isTrue);
    });

    test('markUploaded clears local bytes', () {
      final uploaded = ContentMediaIntentState(
        phase: ContentMediaPhase.pendingLocal,
        localBytes: Uint8List.fromList([4, 5]),
      ).markUploaded('asset-99');

      expect(uploaded.phase, ContentMediaPhase.uploaded);
      expect(uploaded.assetId, 'asset-99');
      expect(uploaded.localBytes, isNull);
    });

    test('markFailed keeps error message', () {
      final failed = ContentMediaIntentState.untouched.markFailed('network');
      expect(failed.phase, ContentMediaPhase.failed);
      expect(failed.error, 'network');
    });

    test('clear resets to untouched with optional asset id', () {
      final cleared = ContentMediaIntentState(
        phase: ContentMediaPhase.pendingLocal,
        localBytes: Uint8List.fromList([7]),
        assetId: 'old',
      ).clear(assetId: 'kept');

      expect(cleared.phase, ContentMediaPhase.untouched);
      expect(cleared.assetId, 'kept');
      expect(cleared.localBytes, isNull);
    });

    test('previewBytes: local overrides resolved cache', () {
      final local = Uint8List.fromList([1, 2, 3]);
      final resolved = Uint8List.fromList([9, 9, 9]);
      final intent = ContentMediaIntentState.untouched.pickLocal(local);
      expect(intent.previewBytes(resolvedBytes: resolved), local);
    });

    test('previewBytes: asset-id-only uses resolved cache after save', () {
      final resolved = Uint8List.fromList([9, 9, 9]);
      final intent = ContentMediaIntentState(assetId: 'asset-1');
      expect(intent.previewBytes(resolvedBytes: resolved), resolved);
      expect(intent.bytesForPreview, isNull);
    });

    test('previewBytes: cleared intent omits resolved cache', () {
      final resolved = Uint8List.fromList([9, 9, 9]);
      final intent = ContentMediaIntentState(assetId: 'asset-1').markRemoved();
      expect(intent.previewBytes(resolvedBytes: resolved), isNull);
    });
  });
}
