import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/tesseract_topic_ocr_impl.dart';

Future<Uint8List> sampleImage(String text) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1500, 500), Paint()..color = Colors.white);
  final painter = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(
              color: Colors.black,
              fontSize: 50,
              fontFamily: 'Roboto',
              height: 1.6)),
      textDirection: TextDirection.ltr)
    ..layout(maxWidth: 1400);
  painter.paint(canvas, const Offset(40, 35));
  final picture = recorder.endRecording();
  final image = await picture.toImage(1500, 500);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  painter.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'native Russian OCR recognizes numbered topics and rejects bad input',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('OCR проверка'))));
    const ocr = TesseractTopicOcrAdapter();
    expect(await ocr.isAvailable(), isTrue);
    final bytes = await sampleImage(
        '1. Высшая математика\n2. Сопротивление материалов\n3. Строительная механика');
    final result = (await ocr.recognize(bytes)).toLowerCase();
    expect(result, contains('математика'));
    expect(result, contains('материалов'));
    expect(result, contains('механика'));
    await expectLater(ocr.recognize(Uint8List(0)), throwsFormatException);
    await expectLater(
        ocr.recognize(Uint8List.fromList([1, 2, 3, 4])), throwsFormatException);
    await expectLater(
        ocr.recognize(await sampleImage('')), throwsFormatException);
    expect(tester.takeException(), isNull);
    await ocr.dispose();
  });
}
