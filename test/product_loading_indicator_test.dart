import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('cat animation fits inline and respects reduced motion',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.runAsync(() => AssetLottie(
          'assets/animations/cat_loader.json',
          package: 'student_ui',
        ).load());
    Future<void> show({required bool reduceMotion, Color? color}) {
      return tester.pumpWidget(MaterialApp(
        theme: ThemeData.light(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Center(child: ProductLoadingIndicator(size: 18, color: color)),
        ),
      ));
    }

    Lottie animation() => tester.widget<Lottie>(find.byType(Lottie));

    await show(reduceMotion: false);
    expect(tester.getSize(find.byType(Lottie)), const Size(18, 18));
    expect(find.bySemanticsLabel('Загрузка'), findsOneWidget);
    semantics.dispose();
    expect(animation().animate, isTrue);
    expect(animation().repeat, isTrue);

    await show(reduceMotion: true);
    await tester.pumpAndSettle();
    expect(animation().animate, isFalse);
    expect(animation().repeat, isFalse);

    await show(reduceMotion: true, color: Colors.white);
    expect(
      find.ancestor(
          of: find.byType(Lottie), matching: find.byType(ColorFiltered)),
      findsOneWidget,
    );
  });
}
