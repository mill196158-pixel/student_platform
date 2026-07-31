import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/info/subject_hero_load.dart';
import 'package:student_platform/src/ui/info/subject_media_service.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('SubjectMediaDownload expires and shouldRefresh', () {
    final fresh = SubjectMediaDownload(
      signedUrl: 'https://example.com/x',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(fresh.isExpired, isFalse);
    expect(fresh.shouldRefresh, isFalse);

    final stale = SubjectMediaDownload(
      signedUrl: 'https://example.com/y',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(stale.isExpired, isTrue);
    expect(stale.shouldRefresh, isTrue);
  });

  test('bytes cache key is user-scoped and version-specific', () {
    final cache = NewsImageBytesCache();
    final service = SubjectMediaService(
      bytesCache: cache,
      currentUserId: () => 'user-a',
    );
    final asset = SubjectCardAsset.tryParse({
      'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'mime_type': 'image/jpeg',
      'byte_size': 100,
      'version_number': 2,
      'asset_kind': 'hero_image',
      'logical_asset_id': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    })!;
    final key = service.bytesCacheKey('off-1', asset);
    expect(key.path, contains('user-a'));
    expect(key.path, contains(asset.id));
    expect(key.version, '2');

    cache.put(key, Uint8List.fromList([9]));
    expect(cache.peek(key)?.single, 9);

    service.clearAsset('off-1', asset);
    expect(cache.peek(key), isNull);
  });

  test('clearAll is safe without Supabase init', () async {
    final service = SubjectMediaService(currentUserId: () => 'user-1');
    await service.clearAll();
  });

  test('P1: rejects Edge response that leaks storage path', () {
    expect(
      SubjectMediaService.responseLeaksStoragePath({
        'signedUrl': 'https://example.com/x',
        'path': 'subject/x/y.png',
      }),
      isTrue,
    );
    expect(
      SubjectMediaService.responseLeaksStoragePath({
        'signedUrl': 'https://example.com/x',
        'storage_path': 'subject/x/y.png',
      }),
      isTrue,
    );
    expect(
      SubjectMediaService.responseLeaksStoragePath({
        'signedUrl': 'https://example.com/x',
        'mimeType': 'image/png',
        'expiresIn': 3600,
        'assetId': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      }),
      isFalse,
    );
  });

  test('P1: hero load generation token ignores stale completions', () {
    expect(
      subjectHeroLoadIsCurrent(startedGeneration: 1, currentGeneration: 1),
      isTrue,
    );
    expect(
      subjectHeroLoadIsCurrent(startedGeneration: 1, currentGeneration: 2),
      isFalse,
    );
  });
}
