import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/subjects/subject_media_store.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('FakeSubjectMediaStore lists and uploads catalog assets', () async {
    final store = FakeSubjectMediaStore();
    expect(
      await store.listAssets(subjectCatalogId: 'cat-1'),
      isEmpty,
    );

    final uploaded = await store.uploadBytes(
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
      fileName: 'hero.png',
      kind: SubjectCardAssetKind.heroImage,
      subjectCatalogId: 'cat-1',
      title: 'Hero',
    );
    expect(uploaded.kind, SubjectCardAssetKind.heroImage);

    final rows = await store.listAssets(subjectCatalogId: 'cat-1');
    expect(rows, hasLength(1));
    expect(rows.single.kind, SubjectCardAssetKind.heroImage);
    expect(rows.single.title, 'Hero');

    await store.deleteAsset(rows.single.id);
    expect(await store.listAssets(subjectCatalogId: 'cat-1'), isEmpty);
  });
}
