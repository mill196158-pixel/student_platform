import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/news/admin_image_store.dart';
import 'package:student_platform_admin/features/content/news/news_editor_screen.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_ui/student_ui.dart';

final Uint8List _pngBytes = Uint8List.fromList(<int>[
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

void main() {
  test('image validation accepts png and rejects oversized files', () {
    final ok = LocalAdminImagePicker.validateAndWrap(
      bytes: _pngBytes,
      fileName: 'card.png',
      mimeType: 'image/png',
    );
    expect(ok.mimeType, 'image/png');

    expect(
      () => LocalAdminImagePicker.validateAndWrap(
        bytes: Uint8List(LocalAdminImagePicker.maxBytes + 1),
        fileName: 'huge.png',
        mimeType: 'image/png',
      ),
      throwsA(isA<AdminImagePickException>()),
    );

    expect(
      () => LocalAdminImagePicker.validateAndWrap(
        bytes: _pngBytes,
        fileName: 'note.gif',
        mimeType: 'image/gif',
      ),
      throwsA(isA<AdminImagePickException>()),
    );
  });

  testWidgets('image survives variant switch in editor', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = LocalAdminImageStore();
    final stored = await store.put(
      bytes: _pngBytes,
      mimeType: 'image/png',
      fileName: 'seed.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsEditorScreen(
            repository: LocalNewsRepository(
              seed: [
                NewsItem(
                  id: 'local-1',
                  title: 'Картинка сохраняется',
                  subtitle: 'При смене варианта',
                  variant: StudentHomeNewsVariant.imageOverlay,
                  colors: const [Color(0xFF246B8E), Color(0xFF54B7AD)],
                  status: NewsStatus.published,
                  imageId: stored.id,
                ),
              ],
            ),
            imageStore: store,
            imagePicker: _FakePicker(null),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Изображение выбрано'), findsOneWidget);

    await tester.tap(
      find.byType(DropdownButtonFormField<StudentHomeNewsVariant>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Только картинка').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Изображение выбрано'), findsOneWidget);
    expect(store.getBytes(stored.id), isNotNull);
  });

  testWidgets('local pick updates preview immediately', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final picker = _FakePicker(
      PickedAdminImage(
        bytes: _pngBytes,
        fileName: 'picked.png',
        mimeType: 'image/png',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewsEditorScreen(
            repository: LocalNewsRepository(
              seed: const [
                NewsItem(
                  id: 'local-1',
                  title: 'Без картинки',
                  subtitle: 'Пока пусто',
                  variant: StudentHomeNewsVariant.imageWithText,
                  colors: [Color(0xFFF3A95F), Color(0xFFE66E75)],
                  status: NewsStatus.draft,
                ),
              ],
            ),
            imageStore: LocalAdminImageStore(),
            imagePicker: picker,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Editor defaults to Published tab; draft seed lives under Drafts.
    await tester.tap(find.byTooltip('Черновики'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Без картинки').first);
    await tester.pumpAndSettle();

    expect(find.text('Выберите изображение'), findsOneWidget);

    await tester.tap(find.text('Выбрать изображение'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Изображение выбрано (не сохранено)'),
      findsWidgets,
    );
    expect(find.byType(StudentHomeView), findsOneWidget);
  });
}
