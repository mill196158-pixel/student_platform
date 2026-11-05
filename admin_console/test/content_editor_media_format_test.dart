import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_editor_screen.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_repository.dart';
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_editor_screen.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_repository.dart';
import 'package:student_platform_admin/features/content/reference/content_media_store.dart';

class _Picker implements AdminImagePicker {
  _Picker(this.image);
  final PickedAdminImage image;
  @override
  Future<PickedAdminImage?> pickImage() async => image;
}

class _Store extends ContentMediaStore {
  String? contentType;
  Uint8List? data;
  @override
  Future<ContentMediaUploadResult> uploadBytesDetailed({
    required String contentItemId,
    required Uint8List bytes,
    required String contentType,
    String title = '',
  }) async {
    this.contentType = contentType;
    data = bytes;
    return const ContentMediaUploadResult(assetId: 'test-asset');
  }

  @override
  Future<Uint8List?> downloadBytes({required String assetId}) async => data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry in [
    ('tiny.jpg', 'image/jpeg'),
    ('tiny.webp', 'image/webp'),
  ]) {
    for (final home in [true, false]) {
      testWidgets('${home ? 'home' : 'profile'} uploads ${entry.$2} bytes', (
        tester,
      ) async {
        AdminBackendConfig.debugDemoModeOverride = true;
        addTearDown(() => AdminBackendConfig.debugDemoModeOverride = null);
        await tester.binding.setSurfaceSize(const Size(1400, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = File('test/fixtures/media/${entry.$1}').readAsBytesSync();
        final picker = _Picker(
          PickedAdminImage(
            bytes: bytes,
            fileName: entry.$1,
            mimeType: entry.$2,
          ),
        );
        final store = _Store();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: home
                  ? HomePromoEditorScreen(
                      repository: LocalHomePromoRepository(),
                      mediaStore: store,
                      imagePicker: picker,
                    )
                  : ProfileFeedEditorScreen(
                      repository: LocalProfileFeedRepository(),
                      mediaStore: store,
                      imagePicker: picker,
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
          find.text(home ? 'Загрузить' : 'Иллюстрация'),
          200,
          scrollable: find.byWidget(scrollable),
        );
        final upload = find.ancestor(
          of: find.text(home ? 'Загрузить' : 'Иллюстрация'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        );
        expect(upload, findsOneWidget);
        tester.widget<OutlinedButton>(upload).onPressed!();
        await tester.pumpAndSettle();
        final save = find.ancestor(
          of: find.text('Сохранить черновик'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        );
        expect(save, findsOneWidget);
        tester.widget<OutlinedButton>(save).onPressed!();
        await tester.pumpAndSettle();
        expect(store.contentType, entry.$2);
        expect(store.data, bytes);
      });
    }
  }
}
