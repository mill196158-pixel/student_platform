import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/news/admin_photo_optimizer.dart';
import 'package:student_platform_admin/features/content/news/admin_photo_choice.dart';

void main() {
  testWidgets('photo, original and cancel require an explicit decision', (tester) async {
    bool? result;
    var completed = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(onPressed: () async {
        result = await showAdminPhotoMode(context);
        completed = true;
      }, child: const Text('Выбрать')),
    ))));
    for (final choice in ['Сжать фото', 'Оригинал', 'Отмена']) {
      completed = false;
      await tester.tap(find.text('Выбрать'));
      await tester.pumpAndSettle();
      expect(find.textContaining('геоданные'), findsOneWidget);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, choice == 'Отмена' ? null : choice == 'Сжать фото');
    }
  });

  test(
    'explicit photo reduces JPEG and preserves source bytes and MIME',
    () async {
      final photo = image.Image(width: 1200, height: 900);
      var state = 123;
      for (var y = 0; y < photo.height; y++) {
        for (var x = 0; x < photo.width; x++) {
          state = (state * 1103515245 + 12345) & 0x7fffffff;
          final n = (state >> 16) & 63;
          photo.setPixelRgb(
            x,
            y,
            (x ~/ 5 + n).clamp(0, 255),
            (y ~/ 4 + n).clamp(0, 255),
            ((x + y) ~/ 10 + n).clamp(0, 255),
          );
        }
      }
      final input = image.encodeJpg(photo, quality: 98);
      final before = Uint8List.fromList(input);
      final encoded = image.encodeJpg(photo, quality: 88);
      expect(input.length, greaterThan(512 * 1024));
    expect(await isEligibleAdminPhotoJpeg(input), isTrue);
      var calls = 0;
      final result = await LocalAdminImagePicker.prepareSelected(
        bytes: input,
        fileName: 'photo.jpeg',
        mimeType: 'image/jpeg',
        photoMode: true,
        optimizer: (_) async {
          calls++;
          return encoded;
        },
      );
      expect(calls, 1);
      expect(result.bytes.length, lessThan(input.length));
      expect(result.mimeType, 'image/jpeg');
      expect(result.fileName, 'photo.jpg');
      expect(input, orderedEquals(before));
    var current = true, staleCalls = 0;
    final stale = LocalAdminImagePicker.prepareSelected(
        bytes: input, fileName: 'photo.jpg', mimeType: 'image/jpeg',
        photoMode: true, isCurrent: () => current,
        optimizer: (_) async { staleCalls++; return encoded; });
    scheduleMicrotask(() => current = false);
    expect((await stale).bytes, orderedEquals(input));
    expect(staleCalls, 0);
      // ignore: avoid_print
      print('JPEG 1200x900: ${input.length} -> ${result.bytes.length} bytes');
    },
  );

  test('original and unsupported JPEGs never call the lossy worker', () async {
    final jpeg = image.encodeJpg(image.Image(width: 1000, height: 1000));
    final oversized = Uint8List(LocalAdminImagePicker.maxBytes + 1)
      ..setRange(0, jpeg.length, jpeg);
    var calls = 0;
    Future<Uint8List?> encoder(Uint8List _) async {
      calls++;
      return null;
    }

    await expectLater(
      LocalAdminImagePicker.prepareSelected(
        bytes: oversized,
        fileName: 'qr.jpg',
        mimeType: 'image/jpeg',
        photoMode: false,
        optimizer: encoder,
      ),
      throwsA(isA<AdminImagePickException>()),
    );
    final original = await LocalAdminImagePicker.prepareSelected(
      bytes: jpeg,
      fileName: 'qr.jpg',
      mimeType: 'image/jpeg',
      photoMode: false,
      optimizer: encoder,
    );
    expect(original.bytes, orderedEquals(jpeg));
    final qr = image.Image(width: 128, height: 128, numChannels: 4);
    for (var y = 0; y < 128; y++) {
      for (var x = 0; x < 128; x++) {
        final color = ((x ~/ 8 + y ~/ 8) % 2) * 255;
        qr.setPixelRgba(x, y, color, color, color, x < 32 ? 0 : 255);
      }
    }
    final png = image.encodePng(qr, level: 0);
    final pngOriginal = await LocalAdminImagePicker.prepareSelected(bytes: png,
        fileName: 'qr.png', mimeType: 'image/png', photoMode: false,
        optimizer: encoder);
    expect(pngOriginal.bytes, orderedEquals(png));
    final icc = Uint8List.fromList([
      ...jpeg.take(2),
      0xff,
      0xe2,
      0,
      6,
      1,
      2,
      3,
      4,
      ...jpeg.skip(2),
    ]);
    expect(await isEligibleAdminPhotoJpeg(icc), isFalse);
    expect(await isEligibleAdminPhotoJpeg(Uint8List.fromList([...jpeg, 0])), isFalse);
    final oversizedUnsupported = Uint8List(LocalAdminImagePicker.maxBytes + 1)
      ..setRange(0, icc.length, icc);
    await expectLater(LocalAdminImagePicker.prepareSelected(
      bytes: oversizedUnsupported, fileName: 'unsupported.jpg',
      mimeType: 'image/jpeg', photoMode: true, optimizer: encoder),
      throwsA(isA<AdminImagePickException>()));
    final exifPhoto = image.Image(width: 100, height: 80);
    exifPhoto.exif.imageIfd.orientation = 1;
    expect(await isEligibleAdminPhotoJpeg(image.encodeJpg(exifPhoto)), isTrue);
    exifPhoto.exif.imageIfd.orientation = 6;
    expect(await isEligibleAdminPhotoJpeg(image.encodeJpg(exifPhoto)), isFalse);
    final exif = Uint8List(44);
    exif.setRange(0, 6, [69, 120, 105, 102, 0, 0]);
    final data = ByteData.sublistView(exif);
    data.setUint16(6, 0x4d4d);
    data.setUint16(8, 42);
    data.setUint32(10, 8);
    data.setUint16(14, 2);
    for (var i = 0; i < 2; i++) {
      final entry = 16 + i * 12;
      data.setUint16(entry, 0x0112);
      data.setUint16(entry + 2, 3);
      data.setUint32(entry + 4, 1);
      data.setUint16(entry + 8, i == 0 ? 1 : 6);
    }
    final duplicate = Uint8List.fromList([...jpeg.take(2), 0xff, 0xe1,
      0, exif.length + 2, ...exif, ...jpeg.skip(2)]);
    expect(await isEligibleAdminPhotoJpeg(duplicate), isFalse);
    for (final unknownTag in [0x014a, 0xc7ff]) {
      data.setUint16(28, unknownTag);
      final unknown = Uint8List.fromList([...jpeg.take(2), 0xff, 0xe1,
        0, exif.length + 2, ...exif, ...jpeg.skip(2)]);
      expect(await isEligibleAdminPhotoJpeg(unknown), isFalse);
    }
    expect(calls, 0);
  });
}
