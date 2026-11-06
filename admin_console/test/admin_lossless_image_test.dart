import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/news/admin_photo_optimizer.dart';

void main() {
  test('legacy JPEG validates upright EXIF and rejects rotation', () async {
    final upright = image.Image(width: 80, height: 40)..exif.imageIfd.orientation = 1;
    final rotated = image.Image(width: 80, height: 40)..exif.imageIfd.orientation = 6;
    final output = image.encodeJpg(image.Image(width: 80, height: 40));
    expect(await isValidLegacyJpeg(image.encodeJpg(upright), output), isTrue);
    expect(await isValidLegacyJpeg(image.encodeJpg(rotated), output), isFalse);
  });
  test(
    'oversized real JPEG can use compatible web encoder without changing source',
    () async {
      final photo = image.Image(width: 2200, height: 2200, numChannels: 3);
      var random = 0x12345678;
      for (var y = 0; y < photo.height; y++) {
        for (var x = 0; x < photo.width; x++) {
          random ^= (random << 13) & 0xffffffff;
          random ^= random >> 17;
          random ^= (random << 5) & 0xffffffff;
          photo.setPixelRgb(
            x,
            y,
            random & 255,
            (random >> 8) & 255,
            (random >> 16) & 255,
          );
        }
      }
      final source = image.encodeJpg(photo, quality: 100);
      expect(source.length, greaterThan(LocalAdminImagePicker.maxBytes));
      expect(source.length, lessThan(LocalAdminImagePicker.maxInputBytes));
      final before = Uint8List.fromList(source);
      final output = image.encodeJpg(
        image.copyResize(photo, width: 1600),
        quality: 88,
      );
      var invoked = false;
      final picked = await LocalAdminImagePicker.prepareSelected(
        bytes: source,
        fileName: 'photo.jpeg',
        mimeType: 'image/jpeg',
        optimizer: (_) async {
          invoked = true;
          return output;
        },
      );
      expect(invoked, isTrue);
      expect(source, before);
      expect(picked.fileName, 'photo.jpg');
      expect(picked.mimeType, 'image/jpeg');
      expect(picked.bytes, output);
      expect(image.decodeJpg(picked.bytes), isNotNull);
      expect(
        picked.bytes.length,
        lessThanOrEqualTo(LocalAdminImagePicker.maxBytes),
      );
      final tiny = image.encodeJpg(image.Image(width: 1, height: 1));
      final distorted = image.encodeJpg(image.Image(width: 1600, height: 800));
      for (final bad in [tiny, distorted]) {
        await expectLater(
          LocalAdminImagePicker.prepareSelected(
            bytes: source,
            fileName: 'photo.jpeg',
            mimeType: 'image/jpeg',
            optimizer: (_) async => bad,
          ),
          throwsA(isA<AdminImagePickException>()),
        );
      }
      expect(source, before);
    },
  );

  test(
    'optimises a QR-like image and alpha without changing any pixel',
    () async {
      final input = image.Image(width: 256, height: 256, numChannels: 4);
      for (var y = 0; y < input.height; y++) {
        for (var x = 0; x < input.width; x++) {
          final value = ((x ~/ 8 + y ~/ 8) % 2) * 255;
          input.setPixelRgba(x, y, value, value, value, (x < 64 ? 0 : 255));
        }
      }
      final source = image.encodePng(input, level: 0);
      final snapshot = Uint8List.fromList(source);
      final picked = await LocalAdminImagePicker.prepareSelected(
        bytes: source,
        fileName: 'qr.jpg',
        mimeType: 'image/jpeg',
      );
      expect(picked.bytes.length, lessThan(source.length));
      expect(picked.fileName, 'qr.png');
      expect(picked.mimeType, 'image/png');
      expect(source, snapshot);
      expect(await isLosslessAdminPhoto(source, picked.bytes), isTrue);
      final decoded = image.decodePng(picked.bytes)!;
      expect(decoded.getPixel(0, 0).a, 0);
      expect(decoded.getPixel(128, 128).a, 255);
      expect(decoded.width, input.width);
      expect(decoded.height, input.height);
    },
  );

  test('retains JPEG, WebP, animated PNG and PNG metadata unchanged', () async {
    final data = image.Image(width: 24, height: 24, numChannels: 4);
    data.setPixelRgba(0, 0, 1, 2, 3, 4);
    final animation = image.Image.from(data)..addFrame(image.Image.from(data));
    final apng = image.encodePng(animation);
    expect(String.fromCharCodes(apng).contains('acTL'), isTrue);
    final meta = image.Image.from(data)..textData = {'description': 'keep'};
    final metadataPng = image.encodePng(meta);
    final jpeg = image.encodeJpg(data);
    final webp = base64Decode(
      'UklGRjYAAABXRUJQVlA4ICoAAACQAQCdASoCAAIAAUAmJaACdLoAA5gA/uC5f/OJfyR+gXdn/3GtufrEAAA=',
    );
    for (final entry in [
      (apng, 'anim.png', 'image/png'),
      (metadataPng, 'meta.png', 'image/png'),
      (jpeg, 'photo.jpeg', 'image/jpeg'),
      (webp, 'photo.webp', 'image/webp'),
    ]) {
      final picked = await LocalAdminImagePicker.prepareSelected(
        bytes: entry.$1,
        fileName: entry.$2,
        mimeType: entry.$3,
      );
      expect(picked.bytes, entry.$1);
      expect(picked.mimeType, entry.$3);
    }
  });

  test(
    'rejects malicious lossy encoder and corrupted PNG without mutation',
    () async {
      final src = image.encodePng(image.Image(width: 64, height: 64), level: 0);
      final snapshot = Uint8List.fromList(src);
      final jpeg = image.encodeJpg(image.Image(width: 2, height: 2));
      final result = await LocalAdminImagePicker.prepareSelected(
        bytes: src,
        fileName: 'original.png',
        mimeType: 'image/png',
        optimizer: (copy) async {
          copy[8] ^= 0xff;
          return jpeg;
        },
      );
      expect(result.bytes, snapshot);
      expect(src, snapshot);
      final corrupted = Uint8List.fromList(src)..[29] ^= 1;
      expect(await optimizeAdminPhoto(corrupted), isNull);
    },
  );
  test('encoder cannot mutate selected bytes after verification', () async {
    final src = image.encodePng(image.Image(width: 128, height: 128), level: 0);
    final candidate = (await optimizeAdminPhoto(src))!;
    final picked = await LocalAdminImagePicker.prepareSelected(
      bytes: src,
      fileName: 'x.png',
      mimeType: 'image/png',
      optimizer: (_) async => candidate,
    );
    final snapshot = Uint8List.fromList(picked.bytes);
    candidate[0] ^= 0xff;
    expect(picked.bytes, snapshot);
  });
}
