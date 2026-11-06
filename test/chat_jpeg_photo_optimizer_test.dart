import 'dart:typed_data';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:student_platform/src/services/chat_jpeg_photo_optimizer.dart';

void main() {
  test('Pillow independently verifies all EXIF orientations', () async {
    final dir =
        await Directory.systemTemp.createTemp('chat_photo_orientation_');
    try {
      final photo = image.Image(width: 480, height: 320);
      for (var y = 0; y < photo.height; y++) {
        for (var x = 0; x < photo.width; x++) {
          photo.setPixelRgb(
              x, y, (x ~/ 2) % 256, (y ~/ 2) % 256, ((x + y) ~/ 4) % 256);
        }
      }
      for (var orientation = 1; orientation <= 8; orientation++) {
        photo.exif.imageIfd.orientation = orientation;
        final original = image.encodeJpg(photo, quality: 98);
        final output = await optimizeChatPhoto(original);
        expect(output.length, lessThan(original.length));
        final source = File('${dir.path}/input.jpg');
        final result = File('${dir.path}/output.jpg');
        await source.writeAsBytes(original);
        await result.writeAsBytes(output);
        final verify = await Process.run('python', [
          '-c',
          'import sys; from PIL import Image, ImageOps, ImageChops, ImageStat\n'
              'a=Image.open(sys.argv[1]); b=Image.open(sys.argv[2])\n'
              'assert b.getexif().get(274)==int(sys.argv[3])\n'
              'a=ImageOps.exif_transpose(a).convert("RGB"); b=ImageOps.exif_transpose(b).convert("RGB")\n'
              'assert a.size==b.size\n'
              'assert max(ImageStat.Stat(ImageChops.difference(a,b)).mean)<8\n',
          source.path,
          result.path,
          '$orientation',
        ]);
        expect(verify.exitCode, 0,
            reason: '${verify.stderr} orientation $orientation');
        await source.delete();
        await result.delete();
      }
    } finally {
      for (final name in ['input.jpg', 'output.jpg']) {
        final file = File('${dir.path}/$name');
        if (await file.exists()) await file.delete();
      }
      await dir.delete();
    }
  }, skip: Platform.environment['RUN_EXTERNAL_JPEG_CHECK'] != '1');

  test('12 megapixel photo is resized with EXIF orientation', () async {
    final photo = image.Image(width: 4000, height: 3000);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        photo.setPixelRgb(
            x, y, (x ~/ 16) % 256, (y ~/ 12) % 256, ((x + y) ~/ 28) % 256);
      }
    }
    photo.exif.imageIfd.orientation = 6;
    final original = image.encodeJpg(photo, quality: 98);
    final output = await optimizeChatPhoto(original);
    final result = image.decodeJpg(output)!;
    expect(output.length, lessThan(original.length));
    expect(result.width, 1536);
    expect(result.height, 2048);
    // ignore: avoid_print
    print('12MP JPEG: ${original.length} -> ${output.length} bytes');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('all eight EXIF orientations survive compression', () async {
    final photo = image.Image(width: 480, height: 320);
    var seed = 7;
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final n = (seed >> 16) & 15;
        photo.setPixelRgb(x, y, (x ~/ 2 + n).clamp(0, 255),
            (y ~/ 2 + n).clamp(0, 255), ((x + y) ~/ 4 + n).clamp(0, 255));
      }
    }
    for (var orientation = 1; orientation <= 8; orientation++) {
      photo.exif.imageIfd.orientation = orientation;
      final input = image.encodeJpg(photo, quality: 98);
      final output = await optimizeChatPhoto(input);
      final result = image.decodeJpg(output)!;
      expect(output.length, lessThan(input.length),
          reason: 'orientation $orientation');
      expect(result.width, orientation >= 5 ? 320 : 480);
      expect(result.height, orientation >= 5 ? 480 : 320);
      final metadata = ByteData.sublistView(output);
      expect(output[20], 0xff);
      expect(output[21], 0xe1);
      expect(metadata.getUint16(40), 0x0112);
      expect(metadata.getUint16(48), orientation);
      final before = image.decodeJpg(input)!;
      for (final point in [
        (0, 0),
        (result.width - 1, 0),
        (0, result.height - 1)
      ]) {
        expect(
            (before.getPixel(point.$1, point.$2).r -
                    result.getPixel(point.$1, point.$2).r)
                .abs(),
            lessThan(15));
      }
    }
  });

  test('explicit photo optimization reduces a synthetic JPEG', () async {
    final photo = image.Image(width: 640, height: 480);
    var seed = 42;
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final noise = (seed >> 16) & 15;
        photo.setPixelRgb(
            x,
            y,
            (x ~/ 3 + noise).clamp(0, 255),
            (y ~/ 2 + noise).clamp(0, 255),
            ((x + y) ~/ 5 + noise).clamp(0, 255));
      }
    }
    final original = image.encodeJpg(photo, quality: 98);
    final result = await optimizeChatPhoto(original);
    final decoded = image.decodeJpg(result)!;
    final before = image.decodeJpg(original)!;
    var absoluteError = 0.0;
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        final a = before.getPixel(x, y), b = decoded.getPixel(x, y);
        absoluteError +=
            (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
      }
    }
    final meanError = absoluteError / (photo.width * photo.height * 3);
    expect(decoded.width, 640);
    expect(decoded.height, 480);
    expect(result.length, lessThan(original.length));
    expect(meanError, lessThan(5));
    // The uploaded bytes, not the source file, determine the transfer size.
    // ignore: avoid_print
    print(
        'JPEG 640x480 quality 98 -> 88: ${original.length} -> ${result.length} bytes; mean RGB error $meanError');
  });

  test('EXIF metadata, trailing bytes and non-JPEG remain unchanged', () async {
    final original = image.encodeJpg(image.Image(width: 32, height: 32));
    final exif = Uint8List.fromList([
      ...original.take(2),
      0xff,
      0xe1,
      0,
      8,
      69,
      120,
      105,
      102,
      0,
      0,
      ...original.skip(2),
    ]);
    for (final value in [
      exif,
      Uint8List.fromList([...original, 0]),
      Uint8List.fromList([137, 80, 78, 71])
    ]) {
      expect(await optimizeChatPhoto(value), orderedEquals(value));
    }
  });

  test('ICC/MPF and cancelled requests retain original bytes', () async {
    final original = image.encodeJpg(image.Image(width: 32, height: 32));
    for (final name in ['ICC_PROFILE\u0000', 'MPF\u0000']) {
      final marker = name.codeUnits;
      final length = marker.length + 2;
      final input = Uint8List.fromList([
        ...original.take(2),
        0xff,
        0xe2,
        length >> 8,
        length & 255,
        ...marker,
        ...original.skip(2),
      ]);
      expect(await optimizeChatPhoto(input), orderedEquals(input));
    }
    final canceled = CancelToken()..cancel();
    expect(await optimizeChatPhoto(original, cancelToken: canceled),
        orderedEquals(original));
  });
}
