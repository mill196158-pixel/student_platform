import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_editor_screen.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_repository.dart';
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/reference/content_media_store.dart';

class _Picker implements AdminImagePicker {
  _Picker(this.getImage);
  final Future<PickedAdminImage?> Function() getImage;
  @override
  Future<PickedAdminImage?> pickImage() => getImage();
}

class _Store extends ContentMediaStore {
  Uint8List? bytes;
  String? mime;
  @override
  Future<ContentMediaUploadResult> uploadBytesDetailed({
    required String contentItemId,
    required Uint8List bytes,
    required String contentType,
    String title = '',
  }) async {
    this.bytes = bytes;
    mime = contentType;
    return const ContentMediaUploadResult(assetId: 'icon-asset');
  }

  @override
  Future<Uint8List?> downloadBytes({required String assetId}) async => bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('icon source validates extension, actual type and 5 MiB boundary', () {
    final png = image.encodePng(image.Image(width: 2, height: 2));
    final exact = Uint8List(LocalAdminImagePicker.maxBytes)
      ..setRange(0, png.length, png);
    final tooLarge = Uint8List(LocalAdminImagePicker.maxBytes + 1)
      ..setRange(0, png.length, png);
    void check(Uint8List bytes, String name) =>
        LocalAdminImagePicker.validateSource(
          bytes,
          name,
          extensions: const ['png', 'webp'],
          byteLimit: LocalAdminImagePicker.maxBytes,
          mimeTypes: const {'image/png', 'image/webp'},
        );
    expect(() => check(exact, 'icon.png'), returnsNormally);
    expect(
      () => check(tooLarge, 'icon.png'),
      throwsA(isA<AdminImagePickException>()),
    );
    expect(
      () => check(png, 'icon.jpg'),
      throwsA(isA<AdminImagePickException>()),
    );
    final jpeg = image.encodeJpg(image.Image(width: 2, height: 2));
    expect(
      () => check(jpeg, 'icon.png'),
      throwsA(isA<AdminImagePickException>()),
    );
  });

  for (final keepOriginal in [true, false]) {
    testWidgets(
      'home icon preview can select ${keepOriginal ? 'original' : 'optimized'} bytes',
      (tester) async {
        AdminBackendConfig.debugDemoModeOverride = true;
        addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
        await tester.binding.setSurfaceSize(const Size(1400, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final original = image.encodePng(
          image.Image(width: 20, height: 20, numChannels: 4),
        );
        final optimized = File(
          'test/fixtures/media/tiny.webp',
        ).readAsBytesSync();
        final picker = _Picker(
          () async => PickedAdminImage(
            bytes: optimized,
            fileName: 'icon.webp',
            mimeType: 'image/webp',
            originalBytes: original,
            originalFileName: 'icon.png',
            originalMimeType: 'image/png',
          ),
        );
        final store = _Store();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomePromoEditorScreen(
                repository: LocalHomePromoRepository(),
                mediaStore: store,
                iconPicker: picker,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Создать черновик'));
        await tester.pumpAndSettle();
        final properties = find
            .ancestor(
              of: find.byWidgetPredicate(
                (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
              ),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Загрузить свою'),
          200,
          scrollable: properties,
        );
        await tester.tap(find.text('Загрузить свою'));
        await tester.pumpAndSettle();
        expect(find.text('Изображение уменьшено'), findsOneWidget);
        expect(store.bytes, isNull);
        await tester.tap(
          find.text(
            keepOriginal ? 'Оставить оригинал' : 'Использовать уменьшенное',
          ),
        );
        await tester.pumpAndSettle();
        final save = find.ancestor(
          of: find.text('Сохранить черновик'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        );
        tester.widget<OutlinedButton>(save).onPressed!();
        await tester.pumpAndSettle();
        expect(store.bytes, orderedEquals(keepOriginal ? original : optimized));
        expect(store.mime, keepOriginal ? 'image/png' : 'image/webp');
      },
    );
  }

  testWidgets('later image selection invalidates pending icon selection', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final delayed = Completer<PickedAdminImage?>();
    final png = image.encodePng(image.Image(width: 20, height: 20));
    final icon = _Picker(() => delayed.future);
    final main = _Picker(() async => null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            iconPicker: icon,
            imagePicker: main,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollable = tester.widget<Scrollable>(properties);
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      200,
      scrollable: find.byWidget(scrollable),
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Загрузить'),
      200,
      scrollable: find.byWidget(scrollable),
    );
    await tester.tap(find.text('Загрузить'));
    await tester.pump();
    delayed.complete(
      PickedAdminImage(bytes: png, fileName: 'old.png', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Убрать иконку'),
      -200,
      scrollable: find.byWidget(scrollable),
    );
    final remove = find.ancestor(
      of: find.text('Убрать иконку'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
  });

  testWidgets('later icon selection invalidates pending image selection', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final delayed = Completer<PickedAdminImage?>();
    final png = image.encodePng(image.Image(width: 20, height: 20));
    final main = _Picker(() => delayed.future);
    final icon = _Picker(() async => null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            iconPicker: icon,
            imagePicker: main,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollable = tester.widget<Scrollable>(properties);
    await tester.scrollUntilVisible(
      find.text('Загрузить'),
      200,
      scrollable: find.byWidget(scrollable),
    );
    await tester.tap(find.text('Загрузить'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      -200,
      scrollable: find.byWidget(scrollable),
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pump();
    delayed.complete(
      PickedAdminImage(bytes: png, fileName: 'old.png', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Убрать'),
      200,
      scrollable: find.byWidget(scrollable),
    );
    final remove = find.ancestor(
      of: find.text('Убрать'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
  });

  testWidgets('injected oversized original is rejected before preview', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final png = image.encodePng(image.Image(width: 20, height: 20));
    final original = Uint8List(LocalAdminImagePicker.maxBytes + 1)
      ..setRange(0, png.length, png);
    final picker = _Picker(
      () async => PickedAdminImage(
        bytes: png,
        fileName: 'icon.png',
        mimeType: 'image/png',
        originalBytes: original,
        originalFileName: 'icon.png',
        originalMimeType: 'image/png',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            iconPicker: picker,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      200,
      scrollable: properties,
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pumpAndSettle();
    expect(find.text('Изображение уменьшено'), findsNothing);
    expect(find.textContaining('Максимум 5 МБ'), findsOneWidget);
  });

  testWidgets('removing an existing icon invalidates a pending replacement', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final png = image.encodePng(image.Image(width: 20, height: 20));
    final delayed = Completer<PickedAdminImage?>();
    var count = 0;
    final picker = _Picker(() {
      if (count++ == 0) {
        return Future.value(
          PickedAdminImage(
            bytes: png,
            fileName: 'first.png',
            mimeType: 'image/png',
          ),
        );
      }
      return delayed.future;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            iconPicker: picker,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      200,
      scrollable: properties,
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pumpAndSettle();
    var remove = find.ancestor(
      of: find.text('Убрать иконку'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNotNull);
    await tester.tap(find.text('Загрузить свою'));
    await tester.pump();
    await tester.tap(find.text('Убрать иконку'));
    await tester.pump();
    delayed.complete(
      PickedAdminImage(bytes: png, fileName: 'late.png', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    remove = find.ancestor(
      of: find.text('Убрать иконку'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
  });

  testWidgets('switching card invalidates a pending icon selection', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final delayed = Completer<PickedAdminImage?>();
    final png = image.encodePng(image.Image(width: 20, height: 20));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            iconPicker: _Picker(() => delayed.future),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      200,
      scrollable: properties,
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pump();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    delayed.complete(
      PickedAdminImage(bytes: png, fileName: 'late.png', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Изображение уменьшено'), findsNothing);
    final remove = find.ancestor(
      of: find.text('Убрать иконку'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
  });
  testWidgets('choosing preset invalidates pending custom icon', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final delayed = Completer<PickedAdminImage?>();
    final png = image.encodePng(image.Image(width: 20, height: 20));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
            iconPicker: _Picker(() => delayed.future),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      200,
      scrollable: properties,
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'ContentIconPickerField',
      ),
      -200,
      scrollable: find
          .ancestor(
            of: find.text('Загрузить свою'),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'ContentIconPickerField',
        ),
        matching: find.byType(OutlinedButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(GridView), matching: find.byType(InkWell))
          .at(1),
    );
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();
    delayed.complete(
      PickedAdminImage(bytes: png, fileName: 'late.png', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    final remove = find.ancestor(
      of: find.text('Убрать иконку'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
  });
  testWidgets('session change during icon pick cannot publish late data', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final delayed = Completer<PickedAdminImage?>();
    final png = image.encodePng(image.Image(width: 20, height: 20));
    final picker = _Picker(() => delayed.future);
    final repository = LocalHomePromoRepository();
    final store = _Store();
    final newSession = AdminSessionController();
    addTearDown(newSession.dispose);
    Widget screen(AdminSessionController? session) => MaterialApp(
      home: Scaffold(
        body: HomePromoEditorScreen(
          repository: repository,
          iconPicker: picker,
          mediaStore: store,
          session: session,
        ),
      ),
    );
    await tester.pumpWidget(screen(null));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Создать черновик'));
    await tester.pumpAndSettle();
    final properties = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Заголовок',
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Загрузить свою'),
      200,
      scrollable: properties,
    );
    await tester.tap(find.text('Загрузить свою'));
    await tester.pump();
    await tester.pumpWidget(screen(newSession));
    await tester.pump();
    delayed.complete(
      PickedAdminImage(bytes: png, fileName: 'late.png', mimeType: 'image/png'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Изображение уменьшено'), findsNothing);
    expect(store.bytes, isNull);
    final remove = find.ancestor(
      of: find.text('Убрать иконку'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
  });
}
