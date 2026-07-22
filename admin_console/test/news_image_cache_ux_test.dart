import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/news/admin_image_store.dart';
import 'package:student_platform_admin/features/content/news/news_editor_screen.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_platform_admin/features/content/news/widgets/news_image_field.dart';
import 'package:student_ui/student_ui.dart';

final Uint8List _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x00,
  0x03,
  0x00,
  0x01,
  0x00,
  0x05,
  0xFE,
  0xD4,
  0xEF,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

class _FakePicker implements AdminImagePicker {
  _FakePicker(this.image);
  final PickedAdminImage? image;
  @override
  Future<PickedAdminImage?> pickImage() async => image;
}

class _FakeRemoteStore implements AdminImageStore, AdminRemoteImageGateway {
  _FakeRemoteStore({
    this.delay = const Duration(milliseconds: 40),
    this.failUpload = false,
  });

  final Duration delay;
  final bool failUpload;
  final Map<String, AdminStoredImage> _local = {};
  final NewsImageBytesCache cache = NewsImageBytesCache();
  int downloadCalls = 0;
  int uploadCalls = 0;
  int _next = 1;

  @override
  Uint8List? getBytes(String imageId) => _local[imageId]?.bytes;

  @override
  String? mimeTypeOf(String imageId) => _local[imageId]?.mimeType;

  @override
  Future<AdminStoredImage> put({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
  }) async {
    final id = 'local-${_next++}';
    final stored = AdminStoredImage(
      id: id,
      bytes: bytes,
      mimeType: mimeType,
      fileName: fileName,
    );
    _local[id] = stored;
    return stored;
  }

  @override
  Future<void> remove(String imageId) async => _local.remove(imageId);

  @override
  Future<Uint8List?> resolveBytes(
    String? imagePath, {
    required String version,
  }) async {
    if (imagePath == null || imagePath.isEmpty) return null;
    final key = NewsImageCacheKey(path: imagePath, version: version);
    return cache.getOrFetch(key, () async {
      downloadCalls += 1;
      await Future<void>.delayed(delay);
      return _png;
    });
  }

  @override
  Uint8List? peekBytes(String? imagePath, {required String version}) {
    if (imagePath == null || imagePath.isEmpty) return null;
    return cache.peek(NewsImageCacheKey(path: imagePath, version: version));
  }

  @override
  void seedRemoteBytes({
    required String path,
    required String version,
    required Uint8List bytes,
  }) {
    cache.put(NewsImageCacheKey(path: path, version: version), bytes);
  }

  @override
  void invalidatePath(String imagePath) => cache.invalidatePath(imagePath);

  @override
  void invalidateKey(String imagePath, String version) {
    cache.invalidateKey(NewsImageCacheKey(path: imagePath, version: version));
  }

  @override
  Future<String> uploadPending(
    String localImageId, {
    String? previousPath,
    String version = '0',
  }) async {
    uploadCalls += 1;
    if (failUpload) {
      throw StateError('upload failed');
    }
    final bytes = getBytes(localImageId);
    if (bytes == null) throw StateError('missing');
    final path = 'news/uploaded-$localImageId.png';
    seedRemoteBytes(path: path, version: version, bytes: bytes);
    if (previousPath != null) invalidatePath(previousPath);
    return path;
  }

  @override
  Future<void> deleteRemote(String imagePath) async {
    invalidatePath(imagePath);
  }

  @override
  void clearPrivateCache() => cache.clear();
}

NewsItem _remoteItem({
  String id = 'n1',
  String path = 'news/a/b.png',
  int version = 2,
}) {
  return NewsItem(
    id: id,
    title: 'С фото',
    subtitle: 'sub',
    body: 'body',
    variant: StudentHomeNewsVariant.imageOverlay,
    colors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
    imagePath: path,
    versionNumber: version,
    updatedAt: DateTime.utc(2026, 7, 22),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NewsImageBytesCache.instance.clear();
  });

  testWidgets('remote image_path shows loading, not pick CTA', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NewsImageField(
            imageBytes: null,
            status: NewsImageFieldStatus.loading,
            onPick: _noop,
            onClear: _noop,
          ),
        ),
      ),
    );
    expect(find.text('Загружаем изображение…'), findsOneWidget);
    expect(find.text('Выберите изображение'), findsNothing);
  });

  testWidgets('editor with remote path never shows pick title while loading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _FakeRemoteStore(delay: const Duration(milliseconds: 80));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsEditorScreen(
            repository: LocalNewsRepository(seed: [_remoteItem()]),
            imageStore: store,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Выберите изображение'), findsNothing);
    expect(find.textContaining('Загружаем'), findsWidgets);

    await tester.pumpAndSettle();
    expect(store.downloadCalls, 1);
    expect(find.text('Изображение сохранено'), findsWidgets);
    expect(find.text('Выберите изображение'), findsNothing);
  });

  testWidgets('reselecting news hits cache without second download', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _FakeRemoteStore();
    final items = [
      _remoteItem(id: 'a', path: 'news/a.png'),
      _remoteItem(id: 'b', path: 'news/b.png'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsEditorScreen(
            repository: LocalNewsRepository(seed: items),
            imageStore: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final afterFirst = store.downloadCalls;

    await tester.tap(find.text('С фото').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('С фото').first);
    await tester.pumpAndSettle();

    expect(store.downloadCalls, afterFirst);
  });

  test('concurrent resolveBytes is single-flight', () async {
    final store = _FakeRemoteStore(delay: const Duration(milliseconds: 50));
    final results = await Future.wait([
      store.resolveBytes('news/x.png', version: '1'),
      store.resolveBytes('news/x.png', version: '1'),
      store.resolveBytes('news/x.png', version: '1'),
    ]);
    expect(store.downloadCalls, 1);
    expect(results.every((e) => e != null), isTrue);
  });

  test('version change invalidates prior cache key', () async {
    final store = _FakeRemoteStore();
    await store.resolveBytes('news/x.png', version: '1');
    expect(store.downloadCalls, 1);
    await store.resolveBytes('news/x.png', version: '2');
    expect(store.downloadCalls, 2);
  });

  testWidgets(
    'refresh restores server image via download, not empty pick CTA',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = _FakeRemoteStore();
      final seed = _remoteItem(path: 'news/server.png', version: 4);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsEditorScreen(
              repository: LocalNewsRepository(seed: [seed]),
              imageStore: store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Выберите изображение'), findsNothing);
      expect(find.text('Изображение сохранено'), findsWidgets);
      expect(store.downloadCalls, 1);
      final key = NewsImageCacheKey.tryParse(
        path: 'news/server.png',
        versionNumber: 4,
        updatedAt: DateTime.utc(2026, 7, 22),
      )!;
      expect(store.peekBytes(key.path, version: key.version), isNotNull);
    },
  );

  testWidgets('upload failure blocks publish and keeps previous image_path', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const oldPath =
        'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.png';
    final store = _FakeRemoteStore(failUpload: true);
    final repo = LocalNewsRepository(
      seed: [
        _remoteItem(
          path: oldPath,
          version: 1,
        ).copyWith(status: NewsStatus.draft),
      ],
    );
    final picker = _FakePicker(
      PickedAdminImage(bytes: _png, fileName: 'new.png', mimeType: 'image/png'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsEditorScreen(
            repository: repo,
            imageStore: store,
            imagePicker: picker,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Заменить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('не сохранено'), findsWidgets);

    // Pending local image must disable publish.
    final publishFinder = find.widgetWithText(FilledButton, 'Опубликовать');
    expect(publishFinder, findsOneWidget);
    final publishBtn = tester.widget<FilledButton>(publishFinder);
    expect(publishBtn.onPressed, isNull);

    await tester.tap(find.text('Сохранить черновик'));
    await tester.pumpAndSettle();

    expect(store.uploadCalls, 1);
    final latest = await repo.getNews('n1');
    expect(latest.imagePath, oldPath);
    expect(find.textContaining('Не удалось загрузить'), findsWidgets);
  });

  testWidgets('logout clears Admin private image cache', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);

    final shared = NewsImageBytesCache.instance;
    shared.put(
      const NewsImageCacheKey(path: 'news/private.png', version: '1'),
      _png,
    );
    expect(shared.entryCount, greaterThan(0));

    final session = AdminSessionController(signOut: () async {});
    session.phase = AdminSessionPhase.ready;
    session.capabilities = const AdminCapabilities(
      userId: 'admin-1',
      permissions: {'content.write'},
      assignments: [],
    );
    await session.signOut();

    expect(shared.entryCount, 0);
    expect(session.phase, AdminSessionPhase.signedOut);
  });

  testWidgets('story sheet precaches next image via resolveImage', (
    tester,
  ) async {
    var resolveCalls = 0;
    final first = StudentHomeNews(
      id: '1',
      title: 'One',
      subtitle: 's',
      body: 'b',
      icon: Icons.auto_awesome_rounded,
      gradientColors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
      variant: StudentHomeNewsVariant.imageOnly,
      imageBytes: _png,
    );
    final second = StudentHomeNews(
      id: '2',
      title: 'Two',
      subtitle: 's',
      body: 'b',
      icon: Icons.auto_awesome_rounded,
      gradientColors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
      variant: StudentHomeNewsVariant.imageOnly,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentNewsStorySheet(
            news: [first, second],
            resolveImage: (item) async {
              resolveCalls += 1;
              return _png;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(resolveCalls, greaterThanOrEqualTo(1));
  });
}

void _noop() {}
