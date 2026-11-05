import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('loading animation keeps its artwork and valid layer parents',
      (tester) async {
    final bytes = await rootBundle.load(
      'packages/student_ui/assets/animations/pigeon_loader.json',
    );
    final json = jsonDecode(utf8.decode(bytes.buffer.asUint8List()))
        as Map<String, dynamic>;
    final asset = (json['assets'] as List).first as Map<String, dynamic>;
    final layers = (asset['layers'] as List).cast<Map<String, dynamic>>();
    final ids = layers.map((layer) => layer['ind']).toSet();
    expect(
        layers.where((layer) => layer['nm'] == 'head Outlines'), hasLength(1));
    for (final layer in layers) {
      final parent = layer['parent'];
      if (parent != null) expect(ids, contains(parent));
    }
  });

  testWidgets('pigeon animation fits inline and respects reduced motion',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.runAsync(() => AssetLottie(
          'assets/animations/pigeon_loader.json',
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
      findsNothing,
    );
  });
}
