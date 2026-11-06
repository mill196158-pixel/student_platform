import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';

class _CountingProvider extends ImageProvider<_CountingProvider> {
  _CountingProvider(this.delegate);
  final MemoryImage delegate;
  int keyRequests = 0;

  @override
  Future<_CountingProvider> obtainKey(ImageConfiguration configuration) {
    keyRequests++;
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
          _CountingProvider key, ImageDecoderCallback decode) =>
      delegate.loadImage(delegate, decode);
}

class _FailingProvider extends ImageProvider<_FailingProvider> {
  @override
  Future<_FailingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          _FailingProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
          Future<ImageInfo>.error(StateError('unavailable')));
}

class _DelayedKeyProvider extends ImageProvider<_DelayedKeyProvider> {
  final keyResult = Completer<_DelayedKeyProvider>();
  @override
  Future<_DelayedKeyProvider> obtainKey(ImageConfiguration configuration) =>
      keyResult.future;
  @override
  ImageStreamCompleter loadImage(
          _DelayedKeyProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
          Future<ImageInfo>.error(StateError('unexpected load')));
}

class _DelayedFrameProvider extends ImageProvider<_DelayedFrameProvider> {
  final frame = Completer<ImageInfo>();
  late final ImageStreamCompleter imageStream =
      OneFrameImageStreamCompleter(frame.future);
  @override
  Future<_DelayedFrameProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          _DelayedFrameProvider key, ImageDecoderCallback decode) =>
      imageStream;
}

void main() {
  testWidgets('disposed gallery consumes a key error after twenty seconds',
      (tester) async {
    final provider = _DelayedKeyProvider();
    await tester
        .pumpWidget(MaterialApp(home: GalleryImageSurface(provider: provider)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
    provider.keyResult.completeError(StateError('late key failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('detached listener is removed after a late frame error',
      (tester) async {
    final provider = _DelayedFrameProvider();
    await tester
        .pumpWidget(MaterialApp(home: GalleryImageSurface(provider: provider)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
    expect(debugGalleryDrains, 1);
    provider.frame.completeError(StateError('late frame failure'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(debugGalleryDrains, 0);
  });
  testWidgets('detached listener is removed after a late successful frame',
      (tester) async {
    final provider = _DelayedFrameProvider();
    await tester
        .pumpWidget(MaterialApp(home: GalleryImageSurface(provider: provider)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
    expect(debugGalleryDrains, 1);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    final image =
        await tester.runAsync(() => recorder.endRecording().toImage(2, 2));
    provider.frame.complete(ImageInfo(image: image!));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(debugGalleryDrains, 0);
  });
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

  testWidgets('gallery keeps transparent pixels readable inside the image',
      (tester) async {
    final key = GlobalKey();
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACgAAAAUCAYAAAD/Rn+7AAAANElEQVR4nO3OsREAIAwDsc/vvzOsQMPFhTWBBji8GRZIOAkn4SSchJNwEk7CuR2oqqriqwtTkQEUzSglOQAAAABJRU5ErkJggg==');
    final provider = _CountingProvider(MemoryImage(bytes));
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: RepaintBoundary(
      key: key,
      child: SizedBox(
          width: 100,
          height: 100,
          child: GalleryImageSurface(provider: provider)),
    ))));
    await tester.runAsync(() => precacheImage(provider, key.currentContext!));
    await tester.pumpAndSettle();
    // One stream for the gallery and one explicit precache in this test.
    expect(provider.keyRequests, 2);
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
    expect(pixel(75, 50), [255, 255, 255, 255]);
    expect(pixel(10, 35), [0, 0, 0, 255]);
    image!.dispose();

    final origin = tester.getTopLeft(find.byType(GalleryImageSurface));
    final first =
        await tester.startGesture(origin + const Offset(40, 50), pointer: 1);
    final second =
        await tester.startGesture(origin + const Offset(60, 50), pointer: 2);
    await first.moveTo(origin + const Offset(15, 50));
    await second.moveTo(origin + const Offset(85, 50));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final zoomed = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
    final zoomData = await tester
        .runAsync(() => zoomed!.toByteData(format: ui.ImageByteFormat.rawRgba));
    final offset = (5 * zoomed!.width + 75) * 4;
    expect(
        Uint8List.sublistView(
            zoomData!.buffer.asUint8List(), offset, offset + 4),
        [255, 255, 255, 255]);
    zoomed.dispose();
  });

  testWidgets('gallery can swipe to the next image', (tester) async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACgAAAAUCAYAAAD/Rn+7AAAANElEQVR4nO3OsREAIAwDsc/vvzOsQMPFhTWBBji8GRZIOAkn4SSchJNwEk7CuR2oqqriqwtTkQEUzSglOQAAAABJRU5ErkJggg==');
    final provider = MemoryImage(bytes);
    final pages = PageController();
    addTearDown(pages.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 200,
      height: 300,
      child: PhotoViewGestureDetectorScope(
          axis: Axis.horizontal,
          child: PageView.builder(
              controller: pages,
              itemCount: 2,
              itemBuilder: (context, index) =>
                  GalleryImageSurface(provider: provider))),
    ))));
    await tester.runAsync(() => precacheImage(
        provider, tester.element(find.byType(GalleryImageSurface).first)));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-175, 0));
    await tester.pumpAndSettle();
    expect(pages.page, closeTo(1, 0.01));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gallery shows a failed image and can replace its source',
      (tester) async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACgAAAAUCAYAAAD/Rn+7AAAANElEQVR4nO3OsREAIAwDsc/vvzOsQMPFhTWBBji8GRZIOAkn4SSchJNwEk7CuR2oqqriqwtTkQEUzSglOQAAAABJRU5ErkJggg==');
    final good = MemoryImage(bytes);
    ImageProvider current = _FailingProvider();
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 100,
      height: 100,
      child: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return GalleryImageSurface(provider: current);
      }),
    ))));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    await tester.runAsync(() =>
        precacheImage(good, tester.element(find.byType(GalleryImageSurface))));
    update(() => current = good);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byType(FullscreenImageSurface), findsOneWidget);
  });
}
