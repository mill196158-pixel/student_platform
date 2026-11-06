// Isolated synthetic Web entrypoint; never included in the normal app build.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;
import 'package:student_platform_admin/features/content/news/admin_image_picker.dart';
import 'package:student_platform_admin/features/content/news/admin_photo_optimizer.dart';

void main() {
  runApp(const MaterialApp(home: Scaffold(body: Text('Synthetic photo QA'))));
  unawaited(_run());
}

Future<void> _run() async {
  final result = <String, Object?>{};
  var stage = 'generate';
  try {
    final response = await html.HttpRequest.request('/synthetic.jpg', responseType: 'arraybuffer');
    final source = Uint8List.view(response.response as ByteBuffer);
    result['before'] = source.length;
    final saved = Uint8List.fromList(source);
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 16), (_) => ticks++);
    final clock = Stopwatch()..start();
    final eligible = await isEligibleAdminPhotoJpeg(source);
    stage = 'photo';
    clock.stop(); timer.cancel();
    final compressed = await LocalAdminImagePicker.prepareSelected(
        bytes: source, fileName: 'synthetic.jpg', mimeType: 'image/jpeg', photoMode: true);
    stage = 'original';
    final original = await LocalAdminImagePicker.prepareSelected(
        bytes: source, fileName: 'synthetic.jpg', mimeType: 'image/jpeg', photoMode: false);
    stage = 'decode';
    final outputPixels = image.decodeJpg(compressed.bytes)!;
    final inputPixels = image.copyResize(image.decodeJpg(source)!,
        width: outputPixels.width, height: outputPixels.height,
        interpolation: image.Interpolation.linear);
    var error = 0.0, samples = 0;
    for (var y = 0; y < outputPixels.height; y += 8) {
      for (var x = 0; x < outputPixels.width; x += 8) {
        final a = inputPixels.getPixel(x, y), b = outputPixels.getPixel(x, y);
        error += (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
        samples += 3;
      }
    }
    result.addAll({'before': source.length, 'after': compressed.bytes.length,
      'mean': error / samples, 'eligible': eligible, 'ticks': ticks,
      'validationMs': clock.elapsedMilliseconds,
      'originalSame': listEquals(original.bytes, saved) && listEquals(source, saved),
      'windowsTarget': defaultTargetPlatform == TargetPlatform.windows,
      'mime': compressed.mimeType});
  } catch (error) {
    result['error'] = error.runtimeType.toString();
    result['stage'] = stage;
  }
  html.document.documentElement!.setAttribute('data-admin-photo-report', jsonEncode(result));
  await html.HttpRequest.getString('/done');
}
