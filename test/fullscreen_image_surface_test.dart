import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';

void main() {
  testWidgets('transparent image has white backing only within its bounds',
      (tester) async {
    final key = GlobalKey();
    final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAOElEQVR4nO3OQQ3AMADEsDT8OW8U9utpihH4AA/fHC6QcTJOxsk4GSfjZJyM83YgSZIkSZIk+a8X4+QBFAcIezwAAAAASUVORK5CYII=');
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: RepaintBoundary(
      key: key,
      child: SizedBox(
          width: 100,
          height: 100,
          child: ColoredBox(
            color: Colors.black,
            child: Center(
                child: FullscreenImageSurface(
                    child: Image.memory(
              imageBytes,
              width: 40,
              height: 40,
            ))),
          )),
    ))));
    await tester.runAsync(
        () => precacheImage(MemoryImage(imageBytes), key.currentContext!));
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
    final data = await tester
        .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
    List<int> pixel(int x, int y) {
      final offset = (y * image!.width + x) * 4;
      return Uint8List.sublistView(
              data!.buffer.asUint8List(), offset, offset + 4)
          .toList();
    }

    expect(pixel(5, 5), [0, 0, 0, 255]);
    expect(pixel(50, 50), [255, 255, 255, 255]);
    expect(pixel(32, 32), [0, 0, 0, 255]);
    image!.dispose();
  });
}
