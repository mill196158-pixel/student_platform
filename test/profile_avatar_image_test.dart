import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/testing.dart';
import 'package:student_platform/src/ui/profile/profile_avatar_image.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/config/supabase_config.dart';

const avatarUrl =
    '${SupabaseConfig.url}/storage/v1/object/public/avatars/a/avatar_v1.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('avatar identity isolates accounts, changes versions and clears removal',
      () {
    final a = profileAvatarImage('a', avatarUrl)!;
    expect(a, profileAvatarImage('a', avatarUrl));
    expect(a, isNot(profileAvatarImage('b', avatarUrl)));
    expect(a, isNot(profileAvatarImage('a', avatarUrl.replaceAll('v1', 'v2'))));
    expect(profileAvatarImage(null, avatarUrl), isNull);
    expect(profileAvatarImage('a', ''), isNull);
    expect(
        profileAvatarImage('a', '$avatarUrl?token=test'), isA<NetworkImage>());
    expect(profileAvatarImage('a', '$avatarUrl?v=2'),
        isA<CachedNetworkImageProvider>());
    expect(
        profileAvatarImage(
            'a',
            avatarUrl.replaceFirst(
                SupabaseConfig.url, 'https://foreign.invalid')),
        isA<NetworkImage>());
    expect(
        profileAvatarImage('a',
            'https://example.com/storage/v1/object/sign/avatars/a?token=test'),
        isA<NetworkImage>());
  });

  test('avatar disk survives new cache manager with no network', () async {
    final dir = await Directory.systemTemp.createTemp('avatar-cache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    var networkCalls = 0;
    final repositories = <JsonCacheInfoRepository>[];
    CacheManager manager() {
      final repo = JsonCacheInfoRepository(path: '${dir.path}/cache.json');
      repositories.add(repo);
      return CacheManager(Config(
        'avatar-test',
        repo: repo,
        fileService: HttpFileService(httpClient: MockClient((_) async {
          networkCalls++;
          throw const SocketException('offline');
        })),
      ));
    }

    final first = manager();
    final provider = profileAvatarImage('a', avatarUrl, cacheManager: first)
        as CachedNetworkImageProvider;
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
    try {
      await first.putFile(avatarUrl, bytes,
          key: provider.cacheKey,
          fileExtension: 'png',
          maxAge: const Duration(days: 1));
      // CacheManager.putFile schedules its metadata write without awaiting it.
      for (var i = 0;
          i < 100 && await repositories.first.get(provider.cacheKey!) == null;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await repositories.first.get(provider.cacheKey!), isNotNull);
      await first.dispose();
      final second = manager();
      try {
        final restored =
            profileAvatarImage('a', avatarUrl, cacheManager: second)
                as CachedNetworkImageProvider;
        final file =
            await second.getSingleFile(restored.url, key: restored.cacheKey);
        expect(await file.readAsBytes(), bytes);
        expect(networkCalls, 0);
        expect(
            await second.getFileFromCache((profileAvatarImage('b', avatarUrl)
                    as CachedNetworkImageProvider)
                .cacheKey!),
            isNull);
      } finally {
        await second.dispose();
      }
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    }
  });

  testWidgets('profile header uses injected image instead of network URL',
      (tester) async {
    final image = MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StudentProfileScreenPreview(
                displayName: 'Test',
                groupLabel: '',
                avatarImage: image,
                avatarUrl: 'https://must-not-load.invalid/image'))));
    expect(
        tester
            .widget<CircleAvatar>(find.byType(CircleAvatar).first)
            .backgroundImage,
        image);
  });
}
