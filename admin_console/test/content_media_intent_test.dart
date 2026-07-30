import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/content_media_intent.dart';

void main() {
  group('ContentMediaIntentState', () {
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
  });
}
