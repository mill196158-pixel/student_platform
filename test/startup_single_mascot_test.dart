import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('one active startup mascot on ${platform.name}',
        (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final boundary = GlobalKey();

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(ProductLoadingIndicator.preload);

      Future<void> show({required bool initializing}) =>
          tester.pumpWidget(RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              navigatorKey: navigator,
              home: SplashLoadingView(initializing: initializing),
            ),
          ));

      Future<void> capture(int ms) async {
        final directory = Platform.environment['STUDENT_MASCOT_FRAMES'];
        if (directory == null) return;
        final image = await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final prefix =
            platform == TargetPlatform.iOS ? 'launch' : 'android-launch';
        await File('$directory/$prefix-$ms.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      }

      final earlyMascot = platform == TargetPlatform.android;
      expect(usesEarlyStartupView, earlyMascot);
      for (final initializing in [true, false]) {
        await show(initializing: initializing);
        await tester.pump();
        if (initializing == earlyMascot) {
          for (final ms in [0, 100, 280, 420]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(find.byType(Lottie), findsOneWidget);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            await tester.runAsync(() => capture(ms));
          }
        } else {
          expect(find.byType(Lottie), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
        }
      }

      navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
            body: Column(children: [
          Lottie.asset('assets/lottie/cat_sleeping.json', height: 150),
          const ProductLoadingIndicator.inline(),
          const ProductLoadingIndicator.inline(),
        ])),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(find.byType(Lottie, skipOffstage: false), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Lottie), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(platform));
  }
}
