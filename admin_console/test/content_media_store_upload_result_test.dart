import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/reference/content_media_store.dart';

void main() {
  test('ContentMediaUploadResult carries working draft row version', () {
    const result = ContentMediaUploadResult(
      assetId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      workingDraftId: '11111111-2222-3333-4444-555555555555',
      workingDraftRowVersion: 3,
    );
    expect(result.assetId, isNotEmpty);
    expect(result.workingDraftRowVersion, 3);
    expect(result.workingDraftId, isNotEmpty);
  });
}
